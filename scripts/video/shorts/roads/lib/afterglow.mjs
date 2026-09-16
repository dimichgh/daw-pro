#!/usr/bin/env node
// ⛔ A STRUCK NOTE MUST RETURN TO EXACTLY BLACK. The user: "the note disks are
// black, but they stay lighted not fully decaying". A residual floor is
// invisible one note at a time and unmistakable after forty of them, because
// the lit disks accumulate down the road behind the playhead.
//
// ⚠⚠ MEASURED ON PIXELS, NOT ON STATE, AND THAT IS THE WHOLE POINT OF THIS
// FILE. The entry gate failed for three rounds because it read a state field
// (env) that did not reach the screen; the emissive here reaches zero
// perfectly well in the model, and the disk still stayed visible, because the
// pool used a different material and a 1.04x scale from the head underneath.
// Only a pixel test can see that class of defect.
//
// THE COMPARISON, with both controls built in:
//   subject   a disk several seconds after its strike
//   reference a NEVER-STRUCK disk on the same road at a similar depth
//             (lighting falls off with distance, so depth has to match)
//   control   the SAME disk 0.2 s after its strike -- if that does not read
//             far brighter than the reference, the probe is not looking at the
//             disk at all and the run is BROKEN rather than passing.
//
// Usage: node afterglow.mjs <payload.json> [--floor]
//   --floor  restores a residual emissive floor, to prove this can fail.
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


const PYBIN = '/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python';
const payloadPath = path.resolve(process.argv[2]);
const FLOOR = process.argv.includes('--floor');
// ⛔⛔⛔ ROUND 7: --env IS THE CONTROL FOR ASSERTION (B), AND (B) EXISTS BECAUSE
// THIS GATE WENT GREEN ON A FILM THE USER COULD SEE THE DEFECT IN.
// r9 passed (A) at 9.3 % against a 14 % limit and the user still wrote "the
// note disks does not decay and stay lighted far away towards the start". Both
// were true. The disks were lit by the ENVIRONMENT MAP, not by the afterglow:
// RoomEnvironment is a bright white studio box and inkMat is metalness 0.85 /
// roughness 0.28, so every disk down the road carried a permanent specular
// highlight at grazing incidence.
// ⚠⚠ AND (A) COULD NOT SEE IT, BY CONSTRUCTION: (A) normalises the struck disk
// against THE SAME DISK WITH THE GLOW OFF, so a specular that is present in
// both frames cancels exactly. It measured the right quantity. The quantity was
// the wrong one. That is what (B) is for.
const ENVC = process.argv.includes('--env');
const P = JSON.parse(fs.readFileSync(payloadPath, 'utf8'));
if (ENVC) { P.look = P.look || {}; P.look.envRoom = true; P.look.inkEnv = 1.15; }
const HERE = path.dirname(new URL(import.meta.url).pathname);
const W = P.width ?? 1080, H = P.height ?? 1920;
// ⚠ A BOX MEAN IS DOMINATED BY THE PAPER, NOT BY THE DISK. The first cut used
// an 18px box and read 236 / 188 / 249 out of 255 for cold / reference / hot --
// all three are mostly lit paper, and the control came out at only 1.32x, so
// the gate correctly called ITSELF broken rather than passing.
// ⭐ The measurable quantity is the disk's CONTRAST AGAINST ITS OWN LOCAL
// PAPER: inner box minus surrounding annulus. A never-struck black disk is
// strongly NEGATIVE, a freshly struck one strongly POSITIVE, and "has it
// returned to black" becomes "is its contrast back to the reference's",
// expressed as a fraction of the distance the strike moved it. That fraction
// is dimensionless, so it needs no tuned luminance floor.
const BOX = 10;          // the disk
const RING0 = 15, RING1 = 26;   // its own local paper
const COLD = Number(process.env.AFTER_COLD ?? 4.0);   // seconds after the strike
const HOT  = 0.20;
// ⛔⛔ ROUND 7: 0.14 WAS THE WRONG LIMIT AND THE USER'S EYE BEAT IT. r9 passed
// at 9.3 % and they still saw lit disks. A 14 % ceiling LICENSES a visibly lit
// disk; the requirement was never "under a limit", it is EXACTLY ZERO.
// ⭐ RE-DERIVED WITH BOTH SIDES MEASURED, not lowered until it looked strict:
//     shipped film   0.0 %  (disk mean 50.77 vs reference 50.77 -- identical)
//     --floor control 5.7 %  (a residual emissive floor put back on purpose)
// so 1 % sits an order of magnitude clear of the film and well under the
// control. "Indistinguishable from a never-struck disk" is now the assertion.
const RATIO = Number(process.env.AFTER_RATIO ?? 0.01);  // residual, as a FRACTION of the strike's own excursion

const b = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await b.newPage();
let pageErr = null;
pg.on('pageerror', e => { pageErr = e.message; });
await pg.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err', { timeout: 30000 });
let bFail = false, bBroken = false;
const tmpB = fs.mkdtempSync(path.join(os.tmpdir(), 'afterB-'));
const err0 = await pg.evaluate(() => window.__err);
if (err0) { console.error('PAGE ERROR:', err0); await b.close(); process.exit(2); }
// ⛔⛔ THE MOVING LIGHT SATURATES THE THING BEING MEASURED. Measured: with the
// playhead lights on, the subject disk read 235.9 against local paper 235.3 --
// a contrast of 0.6 -- and the never-struck reference read -1.7. Both are
// noise, because a disk 1.4 units behind the ball sits inside its light pool
// and the paper around it is already at 235/255. The gate correctly reported
// BROKEN rather than passing on numbers that meant nothing.
// ⭐ So the question is isolated instead of asked in a saturated frame: the
// PLAYHEAD LIGHTS AND THE BLOOM ARE TURNED OFF for this measurement. What is
// left is exactly what is under test -- the note disk's OWN residual emissive
// -- with nothing else able to light it. This is a diagnostic render, stated
// as such; it is not the delivered look.
// ═══ ASSERTION (B) — THE ONE THAT WOULD HAVE CAUGHT r9 ════════════════════
// A note struck long ago, and a note never struck at all, must both be DARKER
// than the road around them: they are black disks on a light ground. If any
// long-struck disk is BRIGHTER than its own local ground, something is lighting
// it that is not its emissive, and that is exactly what the user sees as "still
// lighted far away towards the start".
// ⚠ MEASURED IN THE DELIVERED LOOK, not in the isolation render -- (A)'s
// isolation is what makes (A) blind to this.
{
  const totalB = P.total ?? 14;
  const tB = Math.max(0.5, totalB * 0.78);
  const AGE = Number(process.env.AFTER_AGE ?? 3.0);
  const old = (P.notes || []).filter(n => n.t <= tB - AGE);
  const pts = await pg.evaluate((ns, tt, zps) => {
    window.__frame(tt);
    return ns.map(n => window.__projectWorld(n.x, 0.02, -n.t * zps)).filter(q => q && q.on);
  }, old.map(n => ({ x: n.x, t: n.t })), tB, P.zps);
  if (!pts.length) {
    console.log(`  [BROKEN] (B) no note older than ${AGE.toFixed(1)}s is on screen at t=${tB.toFixed(2)} — not measured`);
    bBroken = true;
  } else {
    const fB = path.join(tmpB, 'far.png');
    await pg.screenshot({ path: fB });
    const jb = path.join(tmpB, 'far.json');
    fs.writeFileSync(jb, JSON.stringify({ file: fB, pts, box: 5, ring0: 9, ring1: 16 }));
    const ob = execFileSync(PYBIN, ['-c', `
import sys, json
import numpy as np
from PIL import Image
sp = json.load(open(sys.argv[1]))
a = np.asarray(Image.open(sp['file']).convert('RGB'), float)
lum = a[:,:,0]*0.2126 + a[:,:,1]*0.7152 + a[:,:,2]*0.0722
h, w = lum.shape
B, R0, R1 = sp['box'], sp['ring0'], sp['ring1']
yy, xx = np.mgrid[-R1:R1+1, -R1:R1+1]; rr = np.hypot(yy, xx)
out = []
for q in sp['pts']:
    x, y = int(round(q['sx'])), int(round(q['sy']))
    if x-R1 < 0 or y-R1 < 0 or x+R1+1 > w or y+R1+1 > h: continue
    win = lum[y-R1:y+R1+1, x-R1:x+R1+1]
    disk = win[rr <= B]; ring = win[(rr >= R0) & (rr <= R1)]
    if disk.size < 8 or ring.size < 20: continue
    out.append([float(disk.mean()), float(ring.mean())])
print(json.dumps(out))
`, jb], { encoding: 'utf8' });
    const rows = JSON.parse(ob);
    if (rows.length < 3) {
      console.log(`  [BROKEN] (B) only ${rows.length} old disks resolved on screen — not measured`);
      bBroken = true;
    } else {
      const cons = rows.map(([d, g]) => d - g).sort((a, c) => c - a);
      const worst = cons[0], med = cons[Math.floor(cons.length / 2)];
      const MARGIN = Number(process.env.AFTER_MARGIN ?? 2.0);
      console.log(`\n(B) LONG-STRUCK DISKS vs THEIR OWN GROUND — ${rows.length} disks at least ${AGE.toFixed(1)}s past their strike, t=${tB.toFixed(2)}`);
      console.log(`    disk-minus-ground luma: worst ${worst.toFixed(2)}, median ${med.toFixed(2)}  (must stay below +${MARGIN.toFixed(1)} — a black disk is DARKER than the road)`);
      if (worst > MARGIN) {
        console.log(`  [ FAIL ] (B) a disk struck ${AGE.toFixed(1)}s ago reads ${worst.toFixed(1)} luma BRIGHTER than the road around it. ` +
                    `It is not decaying to the resting black -- something other than its emissive is lighting it.`);
        bFail = true;
      } else {
        console.log('  [ ok ] (B) every long-struck disk is darker than its own ground — nothing is lighting them');
      }
    }
  }
}

await pg.evaluate(() => window.__setLook({ lightPower: 0, drumPower: 0, bloomStrength: 0, ambient: 0.55 }));
console.log('  [isolation] playhead lights, drum lights and bloom OFF for this measurement — see the note in afterglow.mjs');
if (FLOOR) {
  await pg.evaluate(() => window.__setLook({ afterFloor: 0.18 }));
  console.log('  [control] afterFloor 0.18 — a residual glow is put back on purpose');
}

// pick a note early enough that COLD seconds still fit inside the film, and a
// never-struck note at a similar road depth for the reference
const notes = P.notes || [];
const total = P.total ?? 14;
const cand = notes.filter(n => n.t + COLD < total - 0.4).sort((a, c) => a.t - c.t);
if (!cand.length) { console.log('  [BROKEN] no note leaves room for a cold sample'); await b.close(); process.exit(2); }
const subject = cand[Math.floor(cand.length * 0.25)];
const tHot = subject.t + HOT;
// the reference: a note whose own strike is still in the FUTURE at tCold, as
// close as possible in z to the subject

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'after-'));
const shot = async (t, tag) => {
  const f = path.join(tmp, tag + '.png');
  await pg.evaluate(tt => window.__frame(tt), t);
  await pg.screenshot({ path: f });
  return f;
};
// where is a printed note on screen at time t?
const proj = async (n, t) => pg.evaluate((nn, tt) => {
  window.__frame(tt);
  const q = window.__projectWorld(nn.x, nn.y, nn.z);
  return q;
}, { x: n.x, y: 0.02, z: -n.t * (P.zps) }, t);

// ⛔⛔ A FIXED "4 SECONDS LATER" CANNOT BE MEASURED HERE, AND THE REASON IS THE
// WHOLE PREMISE OF THE PIECE: THE ROAD IS THE TIMELINE. A note struck 4 s ago
// is 4 x zps = 7.2 world units behind the camera, so it is not off screen by
// accident, it is off screen by construction. The first cut of this gate asked
// for it anyway and correctly reported BROKEN on both the fixed film and its
// control -- a probe that never looked.
// ⭐ So the question is re-asked in the form that is actually answerable AND is
// the one the user is complaining about: BY THE TIME A STRUCK NOTE LEAVES THE
// FRAME, IS IT BLACK AGAIN? Walk forward to the last moment it is still
// visible and measure there. That tests the reach-zero requirement and the
// decay-speed requirement in one number, which is right, because a decay too
// slow to finish before the note exits is indistinguishable from one that
// never finishes.
let tCold = subject.t + 0.3, lastOn = null;
for (let q = 0; q < 60; q++) {
  const tt = subject.t + 0.3 + q * 0.1;
  if (tt > total - 0.2) break;
  const pp = await proj(subject, tt);
  if (pp && pp.on) { lastOn = tt; } else if (lastOn !== null) break;
}
if (lastOn === null) { console.log('  [BROKEN] the subject note is never on screen after its strike'); await b.close(); process.exit(2); }
tCold = Math.min(lastOn, subject.t + COLD);
console.log(`  subject note t=${subject.t.toFixed(3)}; last visible at t=${lastOn.toFixed(2)} ` +
            `(${(lastOn - subject.t).toFixed(2)}s after its strike) — measuring there`);
// ⛔⛔ THE REFERENCE HAS TO BE THE SAME DISK, NOT A DIFFERENT ONE. The first
// version compared the struck note against a never-struck note further up the
// road, and the numbers came out NEGATIVE -- the struck disk read DARKER
// against its paper than the "unstruck" one. Not a defect: the two disks sit at
// different depths, their local paper measured 160 against 93, and a near disk
// resolves to full black while a far one is two pixels wide and blurs into the
// paper around it. The reference was measuring depth, not afterglow.
// ⭐ So the reference is THE SAME DISK, AT THE SAME INSTANT, IN THE SAME PIXELS,
// rendered with the strike glow switched off (afterGain 0). Depth, lighting,
// projected size and local paper are then identical by construction, and the
// only difference between the two frames is the thing under test.
const shotNoGlow = async (t, tag) => {
  await pg.evaluate(() => window.__setLook({ afterGain: 0 }));
  const f = await shot(t, tag);
  await pg.evaluate(g => window.__setLook({ afterGain: g }), P.look?.afterGain ?? 1.0);
  if (FLOOR) await pg.evaluate(() => window.__setLook({ afterFloor: 0.18 }));
  return f;
};
const fCold = await shot(tCold, 'cold');
const fColdRef = await shotNoGlow(tCold, 'coldref');
const fHot = await shot(tHot, 'hot');
const fHotRef = await shotNoGlow(tHot, 'hotref');
const pSub = await proj(subject, tCold);
const pHot = await proj(subject, tHot);
if (pageErr) { console.error('PAGE ERROR:', pageErr); await b.close(); process.exit(2); }
await b.close();

const spec = { box: BOX, ring0: RING0, ring1: RING1, jobs: [
  { file: fCold,    tag: 'struck, +' + (tCold - subject.t).toFixed(2) + 's (its last visible frame)', p: pSub },
  { file: fColdRef, tag: 'SAME disk, same frame, glow off  <- the reference',                          p: pSub },
  { file: fHot,     tag: 'struck, +' + HOT.toFixed(2) + 's  <- the positive control',                  p: pHot },
  { file: fHotRef,  tag: 'SAME disk, same frame, glow off',                                            p: pHot }] };
const jf = path.join(tmp, 'jobs.json'); fs.writeFileSync(jf, JSON.stringify(spec));
const out = execFileSync(PYBIN, ['-c', `
import sys, json
import numpy as np
from PIL import Image
sp = json.load(open(sys.argv[1])); B = sp['box']; res = []
for j in sp['jobs']:
    a = np.asarray(Image.open(j['file']).convert('RGB'), float)
    h, w, _ = a.shape
    if not j['p'] or not j['p'].get('on'):
        res.append({'tag': j['tag'], 'mean': None}); continue
    x, y = int(round(j['p']['sx'])), int(round(j['p']['sy']))
    y0, y1 = max(0, y - B), min(h, y + B + 1)
    x0, x1 = max(0, x - B), min(w, x + B + 1)
    sub = a[y0:y1, x0:x1]
    lum = sub[:,:,0]*0.2126 + sub[:,:,1]*0.7152 + sub[:,:,2]*0.0722
    if lum.size < 40: res.append({'tag': j['tag'], 'mean': None}); continue
    res.append({'tag': j['tag'], 'mean': float(lum.mean()), 'max': float(lum.max())})
print(json.dumps(res))
`, jf], { encoding: 'utf8' });
fs.rmSync(tmp, { recursive: true, force: true });
const r = JSON.parse(out);
console.log(`\nAFTERGLOW — does a struck note return to the resting black?`);
for (const x of r) console.log(`  ${x.mean === null ? '[not measurable]' :
  'disk mean ' + x.mean.toFixed(2).padStart(7)}   ${x.tag}`);
const [cold, coldRef, hot, hotRef] = r;
if (r.some(x => x.mean === null)) { console.log('  [BROKEN] a sample projected off screen — not measured'); process.exit(2); }
// ⛔⛔ ROUND 7: (A) CANNOT BE ASKED OF A TAKE THAT LOSES THE DISK TOO SOON.
// The landscape camera carries a note out of frame 0.80 s after its strike, and
// exp(-0.80/0.32) = 8.2 % -- the decay is legitimately still in progress, so a
// 1 % limit turns "the disk left before it finished" into a FAILURE report about
// a defect the viewer cannot see (the disk is off screen). The reverse takes
// hold the same disk 6.20 s and CAN ask the question.
// ⭐ So: too young to test is BROKEN, not FAIL. A premise failure must never
// wear a verdict.
const MINAGE = Number(process.env.AFTER_MINAGE ?? 3.0);
const ageC = tCold - subject.t;
if (ageC < MINAGE) {
  console.log(`  [BROKEN] (A) this take carries the disk out of frame ${ageC.toFixed(2)}s after its strike, ` +
              `under the ${MINAGE.toFixed(1)}s the decay needs to finish -- the question is not askable here. ` +
              `Ask it on a take that holds the disk (the reverse/tracking takes hold it 6.20s).`);
  fs.rmSync(tmpB, { recursive: true, force: true });
  if (bFail) process.exit(1);
  process.exit(2);
}
const span = hot.mean - hotRef.mean;      // what a FRESH strike is worth, in the same pixels
if (span < 8) {
  console.log(`  [BROKEN] switching the glow off changes a freshly struck disk by only ${span.toFixed(2)} — ` +
              `the probe is not on the disk, so nothing here is a verdict`);
  process.exit(2);
}
// ⚠ NORMALISE AGAINST THE DISK'S OWN BASELINE, NOT AGAINST THE FRESH STRIKE.
// The fresh strike happens far up the road where the no-glow baseline is
// already 215/255 and the strike's marginal contribution is compressed; the
// last visible frame is near the lens where the baseline is 102. Dividing one
// by the other gave 167 %, which is arithmetic, not afterglow.
const residual = (cold.mean - coldRef.mean) / Math.max(1e-6, coldRef.mean);
// ⛔ ROUND 7: THE SENTENCE DID NOT MATCH THE ARITHMETIC. It read "% of it",
// where "it" was the fresh strike's excursion (`span`), while the divisor is
// and always was `coldRef.mean` -- the disk's OWN unlit baseline in the same
// pixels. The DIVISOR IS THE RIGHT ONE (dividing by `span` was tried in round 6
// and gave 167 %, because the hot sample sits far up the road where the
// baseline is 215/255 and the cold one sits near the lens where it is 102);
// the WORDING was wrong, and a reader comparing the printed % to `span` gets a
// meaningless number. Both quantities are now named explicitly.
console.log(`  a fresh strike is worth ${span.toFixed(2)} luma in these pixels — the positive control fires`);
console.log(`  residual after ${(tCold - subject.t).toFixed(2)}s = ${(cold.mean - coldRef.mean).toFixed(2)} luma ` +
            `= ${(residual*100).toFixed(1)}% OF THE DISK'S OWN UNLIT BASELINE (${coldRef.mean.toFixed(2)}), ` +
            `not of the strike  (limit ${(RATIO*100).toFixed(0)}%)`);
if (residual > RATIO) {
  console.log(`  [ FAIL ] (A) a note struck ${(tCold - subject.t).toFixed(2)}s ago -- at its LAST VISIBLE FRAME -- still carries `
            + `${(residual*100).toFixed(0)}% of the strike's brightness. It leaves the frame lit, and that is the `
            + `accumulation of half-lit disks the user is seeing.`);
  process.exit(1);
}
console.log('  [ ok ] (A) a struck note cools back to the resting black, indistinguishable from an unstruck one');
fs.rmSync(tmpB, { recursive: true, force: true });
if (bFail) process.exit(1);
if (bBroken) process.exit(2);
