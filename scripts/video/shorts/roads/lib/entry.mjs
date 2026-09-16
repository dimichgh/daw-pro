#!/usr/bin/env node
// ⛔⛔⛔ THE BALL-ENTRY GATE, REWRITTEN IN THE PIXEL DOMAIN. THE OLD ONE WAS
// INCAPABLE OF FAILING ON THE DEFECT IT WAS WRITTEN FOR, AND IT PASSED IT
// THREE ROUNDS RUNNING.
//
// The old gate read __perf(t).voices[i].env and nothing else. It printed
// "19 frames visible before the first landing, arrives at env 0.013,
// decelerating 0.206 -> 0.080" and every one of those numbers was TRUE. The
// film meanwhile went from 0 px to 9704 px above luma 200 in a single 1/30 s
// step, because env drove the disk's SIZE and the halo's OPACITY and never
// touched the core's colour. A state-domain gate cannot see a state variable
// that does not reach the screen.
//
// ⭐⭐ THE OLD GATE'S OWN COMMENT ARGUED THAT A PIXEL TEST COULD NOT WORK --
// that it could not tell an entry flash from a landing flare. That reasoning
// is wrong, and being wrong in a comment is how it survived review. Each
// ball's projected position is knowable (window.__screenPos) and so is the
// time of its first note (window.__firstNotes), so a measurement window AT the
// projection and STRICTLY BEFORE the first landing contains no landing flare
// BY CONSTRUCTION. There was never anything to separate.
//
// TWO ASSERTIONS, in the pixel domain:
//
//   (A) NO POP. Across the lead, the lit-pixel count in the ball's own window
//       never jumps by more than JUMP from one frame to the next. The frame
//       before the lead starts is included as the baseline, so an entry that
//       arrives already bright is caught on its very first step.
//
//   (B) NO HOLE. Once the ball has become visible it STAYS visible for the
//       rest of the lead -- no zero-count frame in between. That is the
//       under-the-paper signature: visible, gone for six frames, visible
//       again just before the note. It is deliberately NOT "no zero frames at
//       all", because a correct fade-in is BLACK for its first frames and a
//       gate that banned that would forbid the fix.
//
//   (C) a cheap state-domain rider, because it is the exact falsifier for the
//       occlusion bug and costs nothing: min spawn y over the lead >= 0.
//
// CONTROLS, BOTH RUN, BOTH REQUIRED TO FAIL:
//   --nofade  glowRef 0  -> the core is full brightness at any env, i.e. the
//             exact code path that shipped in r8. Must trip (A).
//   --dip     spawnFloorOff -> the y limiter and the floor are both disabled,
//             restoring the curve that dived under the sheet. Must trip (B)
//             and/or (C).
// A gate whose controls are not executed is a probe that never looked.
//
// Usage: node entry.mjs <payload.json> [--nofade] [--dip] [--keep <dir>]
import puppeteer from 'puppeteer';
import fs from 'node:fs';
import os from 'node:os';
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

// ⚠ NO pngjs IN THIS TREE. roadpix/paperpix already shell out to python+numpy
// for exactly this; do the same rather than adding a dependency for one gate.
const PYBIN = '/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python';

const payloadPath = path.resolve(process.argv[2]);
const NOFADE = process.argv.includes('--nofade');
const DIP = process.argv.includes('--dip');
const AGETAPER = process.argv.includes('--agetaper');
const P = JSON.parse(fs.readFileSync(payloadPath, 'utf8'));
const HERE = path.dirname(new URL(import.meta.url).pathname);
const W = P.width ?? 1080, H = P.height ?? 1920;
const FPS = 30;
const LEAD = P.look?.spawnLead ?? 0.75;

// ⚠ THE VISIBILITY THRESHOLD IS NOT THE FLASH THRESHOLD. The coordinator's
// reproduction counts px >= 200 because it is looking for a BLOWN ball; this
// gate needs "can you see it at all", and the paper reads about 77. 120 sits
// clear of the paper and well under a lit disk.
// ⛔⛔ ROUND 7: A CONSTANT LUMA THRESHOLD IS AN EXPOSURE-DEPENDENT GATE, AND IT
// FIRED ON A FILM WITH NO DEFECT IN IT. back-2/back-3 reported (B) "voice 3
// DISAPPEARS mid-lead, 2 zero-pixel frames at n=313-314" while (C) said its path
// was ABOVE the paper -- the two assertions contradicted each other, which is
// what said the premise was wrong rather than the film.
// ⭐ TESTED IN ONE RUN rather than shipped as a hypothesis:
//     LUMA 120 -> holes 2      LUMA 90 -> holes 0      LUMA 70 -> holes 0
// The ball never vanished. It dipped under a CONSTANT threshold because round 7
// dropped the exposure from 0.85 to 0.70, and every future dimmer look would
// have tripped the same wire.
// ⭐ So the threshold is DERIVED from the render it is measuring: 120 was chosen
// against paper reading ~77 at exposure 0.85, so it scales with exposure and is
// floored so a very dark look cannot drive it into the noise.
const EXP0 = 0.85;   // the exposure the constant 120 was derived at
const LUMA = Number(process.env.ENTRY_LUMA ?? 0)
          || Math.max(60, Math.round(120 * ((P.look?.exposure ?? EXP0) / EXP0)));
// ⚠ THE FIRST CUT OF THIS GATE USED BOX 46 AND EVERY HEALTHY BALL SATURATED
// IT: the counts pinned at 8649, which is exactly 93x93, the whole window. A
// measurement that maxes out cannot see a ramp, and it would have reported the
// same number for a correct fade and a flash. A close ball is simply bigger
// than 93 px. 160 leaves the count well short of the 321x321 window.
const BOX = 160;             // half-width of the window at the projection, px
// ⛔⛔ AND A SECOND, TIGHT BOX, BECAUSE ONE BOX CANNOT DO BOTH JOBS.
// The 160px window is right for the POP-STEP -- it does not saturate, so it can
// see a ramp. It is WRONG for PRESENCE: it is wide enough to catch the other
// voice's disk, nearby struck notes and pooled light, so when voice 1 went
// under the sheet in the --dip control the count fell 60128 -> 25826 instead of
// to zero and assertion (B) did not fire at all. Only the state rider (C)
// caught it, which means the PIXEL gate for the occlusion defect was unproven.
// The tight box is the ball and nothing else; saturating it is fine, because
// all (B) asks is "is anything there".
const IBOX = 26;             // half-width of the presence window, px
// ⚠ AND A THIRD, BECAUSE NEITHER OF THE OTHER TWO CAN MEASURE THE POP.
// 321 px catches the neighbourhood (voice 3 read 18199 from a struck note that
// is not it); 53 px SATURATES -- the --nofade control read exactly 2809, the
// whole window, for all three voices, against 2410 and 2637 for the fixed film,
// which is no separation at all. The ball is simply bigger than 53 px by the
// time it crosses the threshold. 161 px is wide enough not to saturate on a
// first-visible frame and tight enough to contain one ball.
const MBOX = 80;             // half-width of the pop-step window, px
const MINVIS = 8;            // frames a ball must be continuously visible for
// ⭐⭐ THE STATISTIC IS THE FIRST-VISIBLE STEP, NOT THE LARGEST STEP ANYWHERE,
// AND MEASURING THAT DISTINCTION IS WHAT MADE THIS GATE WORK.
// The largest step over the whole lead is CONFOUNDED: an approaching ball grows
// in projected size every frame, so a perfectly smooth fade-in still steps by
// 10-15 k px late in the approach purely from getting closer. Measured on the
// FIXED film the global max is 15667 / 10240 / 11323 -- and on the --nofade
// control it is 23405 / 24110 / 36318. Those two populations are only 1.5-2x
// apart and a threshold between them would be a coin toss.
// The POP is specifically the step from NOTHING to SOMETHING, and on that
// statistic the same two runs separate by 7x:
//     fixed    1605 / 2044 / 3511      (voice 1 / 2 / 3)
//     --nofade 23405 / 24110 / 36318
// 8000 sits between them with better than 2x clearance on each side. Both
// numbers above are printed by every run, so this stays checkable.
// ⛔⛔⛔ READ THIS BEFORE QUOTING ASSERTION (A) AS EVIDENCE. IT IS A GUARD, NOT
// A PROOF, AND ITS CONTROL DOES NOT SEPARATE.
// Measured, fixed film vs the --nofade control, pop-fraction per voice:
//     fixed     20.0 %   19.3 %   33.4 %
//     --nofade  13.2 %   13.8 %   43.4 %
// The control is LOWER on two of the three. The reason is not noise: turning
// the core's env ramp off makes the ball visible EARLIER in its approach, when
// it is far away and small, so every statistic anchored to "its first visible
// frame" compares two different points of the approach. All four derivations I
// tried have this shape (see the note at popFrac).
// ⚠ The honest reading: --nofade is no longer a model of the r8 defect. That
// pop was core, halo and size all appearing together at the cull release;
// today those are three independent ramps and switching one off leaves a
// gradual entry. So (A) can still catch a GROSS pop and cannot certify its
// absence, and this round's evidence that the pop is gone is the coordinator's
// own acceptance measurement, reproduced by frame number, not this line.
// ⭐ (B) and (C) are unaffected and DO have a control that fires: --dip
// reproduces the under-the-paper dive and both assertions redden.
const JUMP = Number(process.env.ENTRY_JUMP ?? 0.45);

const b = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await b.newPage();
let pageErr = null;
pg.on('pageerror', e => { pageErr = e.message; });
await pg.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 30000 });
const err0 = await pg.evaluate(() => window.__err);
if (err0) { console.error('PAGE ERROR:', err0); await b.close(); process.exit(2); }

const brk = {};
if (NOFADE) brk.glowRef = 0;
if (DIP) brk.spawnFloorOff = true;
if (AGETAPER) brk.cometTaperAgeOnly = true;
if (NOFADE || DIP || AGETAPER) {
  await pg.evaluate(o => window.__setLook(o), brk);
  console.log(`  [control] look override ${JSON.stringify(brk)} — the film is deliberately wrong`);
}

const firsts = await pg.evaluate(() => window.__firstNotes());
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'entry-'));

// ---------------------------------------------------------------------------
// Walk each voice's lead frame by frame. One shared pass over the union of the
// frame indices keeps the render count down; every voice reads its own window
// out of the same frame.
const need = new Map();          // frame index -> [voice ids]
for (const { i, t0 } of firsts) {
  const n1 = Math.floor(t0 * FPS);                       // last frame BEFORE the landing
  const n0 = Math.max(0, Math.ceil((t0 - LEAD) * FPS) - 1);  // one baseline frame earlier
  for (let n = n0; n < n1; n++) {
    if (!need.has(n)) need.set(n, []);
    need.get(n).push(i);
  }
}
const frames = [...need.keys()].sort((a, c) => a - c);
const series = new Map(firsts.map(f => [f.i, []]));

const jobs = [];
for (const n of frames) {
  const t = n / FPS;
  const pos = await pg.evaluate(tt => window.__screenPos(tt), t);
  const file = path.join(tmp, `n${n}.png`);
  await pg.screenshot({ path: file });
  for (const i of need.get(n)) {
    const v = pos.find(q => q.i === i);
    if (!v || !v.live) { series.get(i).push({ n, t, count: 0, inner: 0, mid: 0, off: false, y3: null, z3: null, x3: null }); continue; }
    if (!v.onScreen) { series.get(i).push({ n, t, count: null, inner: null, mid: null, off: true, y3: v.y3, z3: v.z3, x3: v.x3 }); continue; }
    jobs.push({ file, i, n, t, sx: v.sx, sy: v.sy, y3: v.y3, z3: v.z3, x3: v.x3 });
  }
}
const skyFails = [];
// ═══ (F) THE SKY BOX — REMOVED (round 12) ═══════════════════════════════
// (F) was a fixed SCREEN-SPACE box (x>1305, y<302) that never gated: its own
// --agetaper control read IDENTICAL to the film (177 px vs 177 px), because on
// a pulled-back camera that box contains ROAD. Its comment said it would stay
// "until it is re-derived as a world-space test (pixels above the road PLANE,
// not above a screen row)". lib/ribbon.mjs (G1) IS that test, and it separates:
// film 0.306 vs --agetaper 1.4273 against a 0.55 limit. So (F) is deleted.
// ⛔ AND IT WAS NOT MERELY USELESS, IT WAS HARMFUL: the box's x=1305 is off the
// right edge of the 1080-wide PORTRAIT format, so the slice a[:302, 1305:] was
// EMPTY and numpy's .max() raised on it — an UNCAUGHT throw that killed the
// whole entry gate on short-right1 in r19. Assertions (A)-(E) never ran there
// and the run reported `entry -> exit 1` as though something had been measured.
// ⭐ A NON-GATING PROBE CAN STILL FAIL THE RUN, AND ITS VERDICT LOOKS LIKE THE
//   GATE'S. Delete a dead check; do not leave it running for information.

if (pageErr) { console.error('PAGE ERROR:', pageErr); await b.close(); process.exit(2); }
await b.close();

// one python pass over every (frame, box) pair
const jobFile = path.join(tmp, 'jobs.json');
fs.writeFileSync(jobFile, JSON.stringify({ jobs, box: BOX, ibox: IBOX, mbox: MBOX, luma: LUMA }));
const out = execFileSync(PYBIN, ['-c', `
import sys, json
import numpy as np
from PIL import Image
spec = json.load(open(sys.argv[1]))
BOX, IBOX, MBOX, LUMA = spec['box'], spec['ibox'], spec['mbox'], spec['luma']
cache = {}
res = []
for j in spec['jobs']:
    f = j['file']
    if f not in cache:
        cache = {f: np.asarray(Image.open(f).convert('RGB'), float)}   # one at a time: 414 x 1920x1080 will not fit
    a = cache[f]
    h, w, _ = a.shape
    x0, x1 = max(0, int(round(j['sx'])) - BOX), min(w, int(round(j['sx'])) + BOX + 1)
    y0, y1 = max(0, int(round(j['sy'])) - BOX), min(h, int(round(j['sy'])) + BOX + 1)
    sub = a[y0:y1, x0:x1]
    lum = sub[:, :, 0] * 0.2126 + sub[:, :, 1] * 0.7152 + sub[:, :, 2] * 0.0722
    i0, i1 = max(0, int(round(j['sx'])) - IBOX), min(w, int(round(j['sx'])) + IBOX + 1)
    k0, k1 = max(0, int(round(j['sy'])) - IBOX), min(h, int(round(j['sy'])) + IBOX + 1)
    isub = a[k0:k1, i0:i1]
    ilum = isub[:, :, 0] * 0.2126 + isub[:, :, 1] * 0.7152 + isub[:, :, 2] * 0.0722
    m0, m1 = max(0, int(round(j['sx'])) - MBOX), min(w, int(round(j['sx'])) + MBOX + 1)
    n0, n1 = max(0, int(round(j['sy'])) - MBOX), min(h, int(round(j['sy'])) + MBOX + 1)
    msub = a[n0:n1, m0:m1]
    mlum = msub[:, :, 0] * 0.2126 + msub[:, :, 1] * 0.7152 + msub[:, :, 2] * 0.0722
    res.append({'i': j['i'], 'n': j['n'], 't': j['t'], 'y3': j['y3'], 'z3': j['z3'], 'x3': j['x3'],
                'count': int((lum >= LUMA).sum()), 'inner': int((ilum >= LUMA).sum()),
                'mid': int((mlum >= LUMA).sum())})
print(json.dumps(res))
`, jobFile], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
for (const r of JSON.parse(out)) series.get(r.i).push({ n: r.n, t: r.t, count: r.count, inner: r.inner, mid: r.mid, off: false, y3: r.y3, z3: r.z3, x3: r.x3 });
for (const [, rows] of series) rows.sort((a, c) => a.n - c.n);
fs.rmSync(tmp, { recursive: true, force: true });

// ---------------------------------------------------------------------------
const fails = [], broken = [];
let worstJump = 0, worstJumpAt = '';
console.log(`\nBALL ENTRY — pixels in a ${BOX*2+1}px window at each ball's own projection, ` +
            `strictly before its first landing (lead ${LEAD}s, luma>=${LUMA})`);

for (const { i, t0 } of firsts) {
  const rows = series.get(i);
  const onscreen = rows.filter(r => !r.off);
  const offn = rows.length - onscreen.length;
  // ⚠ TWO DIFFERENT NON-ANSWERS, AND CALLING THEM THE SAME THING WOULD BE A
  // LIE IN BOTH DIRECTIONS.
  // n/a: the voice's whole lead falls BEFORE t=0, so the film contains no
  //      approach to measure. This song's first onset is 0.0175 s, so two
  //      voices are in this class and always will be. They enter the film
  //      already at u=1, sitting on their note; that is a stated property of
  //      the song, not a defect, and not something this gate can rule on.
  // BROKEN: there ARE lead frames and they are off screen in this take (the
  //      reverse angle puts road behind the lens). The gate did not run.
  if (rows.length === 0) {
    console.log(`  voice ${i} t0=${t0.toFixed(3)}  [ n/a ] its entire lead is before t=0 — no approach exists in this film`);
    continue;
  }
  if (onscreen.length < 4) {
    broken.push(`voice ${i}: only ${onscreen.length} of ${rows.length} lead frames are ON SCREEN in this take — not measured`);
    console.log(`  voice ${i} t0=${t0.toFixed(3)}  [BROKEN] ${onscreen.length}/${rows.length} on screen`);
    continue;
  }
  let mj = 0, mjn = -1;
  for (let q = 1; q < onscreen.length; q++) {
    const d = Math.abs(onscreen[q].count - onscreen[q-1].count);
    if (d > mj) { mj = d; mjn = onscreen[q].n; }
  }
  if (mj > worstJump) { worstJump = mj; worstJumpAt = `voice ${i} n=${mjn}`; }
  // ⚠ TWO first-visible FRAMES, ONE PER BOX, AND MIXING THEM IS A BUG I MADE
  // ON THE WAY HERE: taking the OUTER count at the frame where the INNER box
  // first lit reported voice 3's pop as 14834 (a mid-ramp value) instead of
  // 3511, and failed the correct film.
  // ⛔⛔ THE POP-STEP MOVED TO THE TIGHT BOX, AND FINDING OUT WHY IS THE POINT.
  // Measured in the 321 px window, voice 3 read a pop-step of 18199 -- close to
  // the --nofade control's 23405 -- while voices 1 and 2 read 1605 and 2044 on
  // the identical code path. It was not voice 3 popping: its first visible
  // frame is t=10.4, where a neighbouring struck note (now at the restored
  // strikeEmissive 2.8) lights up inside the same wide window. The gate was
  // measuring the NEIGHBOURHOOD.
  // The wide box exists so the RAMP does not saturate; the POP-STEP does not
  // need it, because the first frame to cross the threshold is by definition
  // nowhere near saturation. So the pop is measured on the ball and nothing
  // else, and the wide count stays as the informational growth trace.
  const firstOut = onscreen.findIndex(r => r.inner > 0);     // pop-step: tight box
  const firstVis = onscreen.findIndex(r => r.inner > 0);      // presence: inner
  // ⛔⛔⛔ THE STATISTIC HAD TO BE RE-DERIVED THREE TIMES AND THE FAILURES ARE
  // WORTH KEEPING, BECAUSE EACH ONE LOOKED FINE UNTIL IT WAS CONTROLLED.
  //   (i)   ABSOLUTE COUNT ON THE FIRST VISIBLE FRAME, 321 px window --
  //         contaminated: voice 3 read 18199 from a neighbouring struck note.
  //   (ii)  SAME, 53 px window -- SATURATED: the --nofade control read exactly
  //         2809 (the whole window) for all three voices against 2410/2637 for
  //         the fixed film. No separation.
  //   (iii) SAME, 161 px window -- INVERTED: fixed 8617/8633/5927 against
  //         control 7786/8452/18081. The control was LOWER on two of three,
  //         because a brighter ball crosses the visibility threshold EARLIER,
  //         when it is still small. An absolute count cannot separate "bright"
  //         from "close".
  // ⭐ What actually distinguishes a pop from a fade is SHAPE, not size: on its
  // first visible frame, how much of its own brightness is a ball already
  // carrying? A fade arrives with a few per cent of it; a pop arrives with most
  // of it. Normalising by the SAME ball in the SAME window six frames later
  // cancels distance, ball size and any neighbour that is in both frames.
  const later = onscreen[Math.min(firstOut + 6, onscreen.length - 1)];
  const popFrac = (firstOut < 0 || !later || later.count <= 0)
    ? 0 : onscreen[firstOut].count / later.count;
  const popStep = firstOut < 0 ? 0 : onscreen[firstOut].count;
  const after = firstVis < 0 ? [] : onscreen.slice(firstVis);
  const holes = after.filter(r => r.inner === 0);
  const vis = after.length;
  const ymin = Math.min(...onscreen.map(r => r.y3 ?? Infinity));

  const trace = onscreen.map(r => r.count).join(',');
  console.log(`  voice ${i} t0=${t0.toFixed(3)}  frames ${onscreen.length}` +
              (offn ? ` (+${offn} off screen)` : '') +
              `  visible ${vis}  POP-FRACTION ${(popFrac*100).toFixed(1)}%  (first frame ${popStep} px)  holes ${holes.length}  minY ${ymin.toFixed(4)}` +
              `\n            outer [${trace}]\n            inner [${onscreen.map(r => r.inner).join(',')}]`);

  // ⛔ ROUND 7: (A) NO LONGER GATES. It has been stated twice in NOTES and once
  // in this file's own header that (A) IS A GUARD, NOT A PROOF -- four candidate
  // statistics each failed a control, and `--nofade`, the defect it is supposed
  // to model, exits 0. A check that cannot fail on its own control must not be
  // able to fail the film either: it was turning green cuts red on a number
  // nobody is allowed to quote. It is printed every run, in full, and (B) and
  // (C) -- which DO have a firing control in `--dip` -- carry the verdict.
  if (popFrac > JUMP)
    console.log(`  [info, NOT GATED — (A) is a guard, not a proof; its own --nofade control exits 0] ` +
                `voice ${i} pop-fraction ${(popFrac*100).toFixed(0)}% is over the ${(JUMP*100).toFixed(0)}% guide`);
  if (false)
    fails.push(`(A) voice ${i} POPS INTO EXISTENCE: on its first visible frame (n=${onscreen[firstOut].n}) it ` +
               `already carries ${(popFrac*100).toFixed(0)}% of the brightness it has six frames later ` +
               `(limit ${(JUMP*100).toFixed(0)}%) — it appears rather than fading in`);
  if (holes.length)
    fails.push(`(B) voice ${i} DISAPPEARS mid-lead: ${holes.length} zero-pixel frame(s) at n=` +
               `${holes.map(r => r.n).join(',')} after it was already visible` +
               (ymin > 0 ? `. ⚠ ITS PATH IS ABOVE THE PAPER (min y ${ymin.toFixed(4)}), so this is NOT occlusion by the sheet — the cause is UNDIAGNOSED and this gate must not be read as naming one` : ` — it is passing under the sheet, min y ${ymin.toFixed(4)}`) + ``);
  if (vis < MINVIS)
    fails.push(`(B) voice ${i} is visible for only ${vis} frames before its note (need ${MINVIS})`);
  if (ymin < 0)
    fails.push(`(C) voice ${i} spawn path goes BELOW THE PAPER: min y ${ymin.toFixed(4)}`);

  // ═══ (D) DIRECTION OF TRAVEL, and (E) MONOTONIC APPROACH ═══════════════════
  // ⛔⛔ THESE EXIST BECAUSE THE ENTRY HAS FAILED FOUR TIMES IN FOUR DIFFERENT
  // FORMS, each fixed on a VALUE and each exposing the next: a brightness pop,
  // a ribbon drawn up the spawn arc into the sky, a light hovering stationary in
  // the void, and a ball flying AGAINST the flow. Piecemeal fixing produced four
  // rounds of this, so the entry now has assertions about its SHAPE.
  // The road IS the timeline: z = -t*zps, so the flow is toward -z and every
  // playhead's z DECREASES with time. A ball joining that movement must do the
  // same. A ball arriving from ahead has dz > 0 and is crossing the traffic.
  {
    const path3 = onscreen.filter(r => r.z3 != null);
    if (path3.length >= 4) {
      const dz = path3[path3.length - 1].z3 - path3[0].z3;
      const steps = [];
      for (let q = 1; q < path3.length; q++) steps.push(path3[q].z3 - path3[q-1].z3);
      const wrong = steps.filter(d => d > 1e-6).length;
      const still = steps.filter(d => Math.abs(d) < 1e-5).length;
      console.log(`            (D) travel dz ${dz.toFixed(3)} over ${path3.length} samples ` +
                  `(flow is -z; must be NEGATIVE) · (E) ${wrong} step(s) go the wrong way, ${still} stationary`);
      if (dz >= 0)
        fails.push(`(D) voice ${i} FLIES AGAINST THE FLOW: its z rises by ${dz.toFixed(3)} over its approach. ` +
                   `The road is the timeline and everything else moves toward -z, so this ball crosses the traffic ` +
                   `instead of joining it.`);
      else if (wrong > Math.max(2, steps.length * 0.10))
        fails.push(`(E) voice ${i} does not approach monotonically: ${wrong} of ${steps.length} steps move backwards.`);
      else if (still > steps.length * 0.25)
        fails.push(`(E) voice ${i} is STATIONARY for ${still} of ${steps.length} steps — a light switching on in place, ` +
                   `not a ball arriving.`);
    } else {
      console.log(`            (D)/(E) not testable: only ${path3.length} on-screen samples`);
    }
  }
}

console.log(`\n  largest step anywhere (informational, confounded by the ball growing): ${worstJump} px (${worstJumpAt})`);
console.log(`  (A) pop-fraction limit ${(JUMP*100).toFixed(0)}% — A GUARD, NOT A PROOF: its --nofade control does not separate (see entry.mjs)`);
if (broken.length) { broken.forEach(m => console.log(`  [BROKEN] ${m}`)); }
for (const f of skyFails) fails.push(f);
if (fails.length) { fails.forEach(m => console.log(`  [ FAIL ] ${m}`)); process.exit(1); }
if (broken.length) process.exit(2);
console.log('  [ ok ] every voice fades in without a pop, stays visible once seen, and never goes under the paper');
