#!/usr/bin/env node
// ⭐⭐ (G) THE WORLD-SPACE RIBBON GUARD + THE APPROACH-TAIL ASSERTION.
//
// Two questions, one run, because they are the two halves of the same change:
//   (G1) NO RIBBON VERTEX MAY SIT HIGH ABOVE THE ROAD PLANE, ever, in any take.
//        That is what the r9 sky-tube defect actually WAS -- cream columns of
//        ribbon standing in the air. The screen-space box that used to guard it
//        was unusable (its control read 177 px against the film's 177), because
//        a fixed screen region contains ROAD on a pulled-back camera. World
//        space is camera-independent and is the quantity that was wrong.
//   (G2) THE TAIL MUST EXIST DURING THE APPROACH, strictly BEFORE the first
//        landing. The user asked twice and got a bare approach twice, because
//        the ribbon's sample window was clamped to the first landing.
//
// ⚠ (G2) MUST BE MEASURED INSIDE THE APPROACH WINDOW. Measuring "tails present"
// over the whole film is the exact shape that has burned this project
// repeatedly: right answer, wrong frames. Every sample here is strictly before
// the voice's first note.
//
// Controls, both of which must fire:
//   --agetaper   restores the age-relative taper  -> (G1) should fail
//   --clamp      restores the first-landing clamp -> (G2) should fail
import puppeteer from 'puppeteer';
import fs from 'node:fs';
import path from 'node:path';

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


const P = JSON.parse(fs.readFileSync(path.resolve(process.argv[2]), 'utf8'));
const AGETAPER = process.argv.includes('--agetaper');
const CLAMP = process.argv.includes('--clamp');
const HERE = path.dirname(new URL(import.meta.url).pathname);
const MAXY = Number(process.env.RIBBON_MAXY ?? 0.55);   // world units above the road plane

const b = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await b.newPage();
await pg.setViewport({ width: P.width, height: P.height });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
if (AGETAPER) { P.look = P.look || {}; P.look.cometTaperAgeOnly = true; }
if (CLAMP)    { P.look = P.look || {}; P.look.cometClampToLanding = true; }
// ⚠ (G1)'s CONTROL NEEDS THE OLD SKY-ARC SPAWN, NOT JUST THE OLD TAPER. Measured:
// --agetaper alone leaves the highest ribbon point at 0.306, UNCHANGED, because
// round 10 moved the spawn path down into the lane -- the geometry that made the
// sky tubes is gone. The defect took BOTH. So the control restores both.
if (AGETAPER) { P.look = P.look || {}; P.look.spawnUp = 1.45; P.look.spawnBack = 3.1; P.look.spawnDx = 0.22; }
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err');
const err = await pg.evaluate(() => window.__err);
if (err) { console.error('PAGE ERROR:', err); await b.close(); process.exit(2); }
if (AGETAPER) console.log('  [control] cometTaperAgeOnly — the age-relative taper is restored on purpose');
if (CLAMP)    console.log('  [control] cometClampToLanding — the first-landing clamp is restored on purpose');

const firsts = await pg.evaluate(() => window.__firstNotes());
const total = P.total ?? 14, FPS = 30, LEAD = P.look?.spawnLead ?? 0.75;
const fails = [];

// ---- (G1) whole-film sweep of the highest ribbon point ---------------------
let worst = -1e9, worstT = null, seen = 0;
for (let n = 0; n < Math.floor(total * FPS); n += 2) {
  const r = await pg.evaluate(tt => window.__ribbonMaxY(tt), n / FPS);
  if (!r || r.maxY === null) continue;
  seen += r.verts;
  if (r.maxY > worst) { worst = r.maxY; worstT = n / FPS; }
}
console.log(`(G1) RIBBON HEIGHT ABOVE THE ROAD PLANE — ${seen} vertices sampled over ${Math.floor(total*FPS/2)} frames`);
if (!seen) { console.log('  [BROKEN] (G1) no ribbon vertices anywhere — nothing measured'); await b.close(); process.exit(2); }
console.log(`     highest ribbon point ${worst.toFixed(4)} at t=${worstT.toFixed(2)} (limit ${MAXY})`);
if (worst > MAXY)
  fails.push(`(G1) a ribbon vertex stands ${worst.toFixed(3)} above the road plane at t=${worstT.toFixed(2)} (limit ${MAXY}). ` +
             `That is the sky-tube defect: the trail is being drawn where there is no road.`);
else console.log('  [ ok ] (G1) every ribbon vertex hugs the road');
console.log('  ⚠ (G) IS A PER-LOOK GATE PRESENTED PER-CUT: __ribbonMaxY is WORLD-space,');
console.log('    so these numbers are byte-identical across every camera of one look.');
console.log('    Four cuts yield ONE verdict four times — the same criticism sync.py carries.');

// ---- (G2) the tail exists DURING THE APPROACH ------------------------------
console.log(`\n(G2) TAIL DURING THE APPROACH — strictly before each voice's first note (lead ${LEAD.toFixed(2)}s)`);
for (const { i, t0 } of firsts) {
  if (t0 - LEAD < 0) { console.log(`  voice ${i} [ n/a ] its lead starts before t=0`); continue; }
  const rows = [];
  for (let q = 1; q <= 6; q++) {
    const t = t0 - LEAD + (LEAD * q / 7);          // 6 samples spread across the approach
    // ⚠ `q.len[vi] ?? 0` THROWS IF `len` IS ABSENT, and a throw here exits 1 —
    // indistinguishable from a measured failure. Missing `len` is a PREMISE
    // failure: the accessor did not return what this gate reads.
    const r = await pg.evaluate((tt, vi) => {
      const q = window.__ribbonMaxY(tt);
      if (!q || !q.len) return null;
      return q.len[vi] ?? 0;
    }, t, i);
    if (r === null) {
      console.error('  [BROKEN] __ribbonMaxY returned no `len` map — (G2) cannot be measured');
      await b.close(); process.exit(2);
    }
    rows.push({ t, len: r || 0 });
  }
  const MINLEN = Number(process.env.RIBBON_MINLEN ?? 0.25);   // world units of trail behind the ball
  // ⚠ THE FIRST SAMPLE IS EXEMPT, AND THIS IS PHYSICS, NOT A FUDGE. At the
  // instant a ball appears it has travelled nowhere, so its trail is length 0 by
  // definition; asserting otherwise would demand a tail behind a ball that has
  // not moved. Every LATER sample must show a real trail. The --clamp control
  // reads 0.00 at ALL SIX samples, so the exemption cannot hide the defect.
  const empty = rows.slice(1).filter(r => r.len < MINLEN).length;
  console.log(`  voice ${i} t0=${t0.toFixed(3)}  trail LENGTH at ` +
              rows.map(r => `t=${r.t.toFixed(2)}:${r.len.toFixed(2)}`).join(' ') + `  (min ${MINLEN})`);
  if (empty)
    fails.push(`(G2) voice ${i} has NO TRAIL at ${empty} of ${rows.length} approach samples — ` +
               `the fly-in is bare and the tail only appears at the bounce.`);
}
if (!fails.some(f => f.startsWith('(G2)'))) console.log('  [ ok ] (G2) every voice trails a ribbon through its whole approach');

await b.close();
if (fails.length) { for (const f of fails) console.error(`  [ FAIL ] ${f}`); process.exit(1); }
console.log('\n  [ ok ] the ribbon hugs the road and exists through every fly-in');
