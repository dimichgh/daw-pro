#!/usr/bin/env node
// ⭐⭐ (R) A VOICE THAT ALREADY EXISTS NEVER DIES AND IS NEVER REBORN.
//
// ⛔⛔ THIS GATE'S ASSERTION WAS INVERTED ON 2026-09-07, ON THE USER'S WORDS.
// Round 13 built it to demand that a voice returning after a rest FLIES IN.
// It did, and the user watched the result:
//   "starting from 26, one disk on the right side fades and a new one shows up
//    and then it happens one more time. Instead it should not fade and just
//    keep flying."
// Their two events are this gate's two re-entries — voice 4 at t=27.875 and
// voice 3 at t=30.017, both on road 2, the right-hand Bass road. So the fly-in
// was not mistuned, it was the wrong ANSWER, and the assertion below is now its
// OPPOSITE: through a rest the light must stay alive, keep travelling, and never
// spawn a second time.
//
// ⚠ THE ORIGINAL DEFECT MUST NOT COME BACK EITHER. What the observer measured on
// r19 — env 0.0001 dark at t=7.000, env 1.0531 live at t=7.033, ONE FRAME,
// 10,500x, `spawning: false` — was real. "Keep it alive" answers it more
// directly than "fly in again" did, and (R3) below is what holds that.
//
// WHAT IS ASSERTED, at every rest long enough to have gone dark under the old
// fade, sampled at the film's own 30 fps across the WHOLE rest:
//   (R1) `live` is true at every single frame — no false, so no false->true
//        transition, so no second birth and no one-frame appearance.
//   (R2) `spawning` is false at every frame — re-entry no longer spawns at all.
//   (R3) inside the rest the env ratio between consecutive frames stays under
//        STEP (1.10) — the light DIMS smoothly, it does not step. The strike at
//        the far end is deliberately NOT in this window: a strike is a strike,
//        and (R4) measures it against ordinary strikes instead.
//   (R4) the strike ending the rest must be no bigger than the strikes this film
//        already makes everywhere else. Reported with its comparison.
//   (R5) the comet stays continuous: the ribbon has >= 3 points at every frame of
//        the rest, so the tail never vanishes and restarts.
//   (R6) globally, no voice ever goes dark between its first note and the end of
//        its last one.
//
// TWO CONTROLS, BOTH OF WHICH MUST FAIL, and neither of which is a deleted-code
// resurrection — each is one line of payload `look`:
//   --r13  {idleFloor: 0, spawnReentry: true}  the fly-in the user rejected
//   --r19  {idleFloor: 0}                      the original switch-on-in-place
// ⚠ THE r13 CONTROL NEEDS BOTH FLAGS. `spawnReentry` alone against a live floor
// is a THIRD behaviour — the spawn env starts at 0 and would snuff a light still
// burning at the floor, which is the bug round 13 caught in its own first cut.
//
// ⚠ HISTORY, SUPERSEDED NOT DELETED: `spawnReentryOff` (round 13's control, which
// forced the fly-in off) still works and still forces it off. It is now the
// DEFAULT behaviour, so as a control it is a no-op — reentry-repro.mjs still
// passes it and still runs.
import puppeteer from 'puppeteer';
import fs from 'node:fs';
import path from 'node:path';

const __GATE = new URL(import.meta.url).pathname.split('/').pop();
const __broke = e => {
  console.error(`  [BROKEN] ${__GATE} crashed before it could measure a thing: ` +
                `${(e && e.message) || e}`);
  console.error(`  [BROKEN] this is NOT a failed assertion — the gate has NO VERDICT here.`);
  process.exit(2);
};
process.on('uncaughtException', __broke);
process.on('unhandledRejection', __broke);

const HERE = path.dirname(new URL(import.meta.url).pathname);
const R13 = process.argv.includes('--r13');
const R19 = process.argv.includes('--r19') || process.argv.includes('--off');
const STEP = Number(process.env.REENTRY_STEP ?? 1.10);
const P = JSON.parse(fs.readFileSync(path.resolve(process.argv[2]), 'utf8'));
P.look = P.look || {};
if (R13 || R19) P.look.idleFloor = 0;      // the extinguishing fade, restored
if (R13) P.look.spawnReentry = true;       // ...plus the fly-in on top of it

// THE RESTS, derived from the payload with the SAME arithmetic road.html uses.
// ⚠ The `rest > DARK` test is kept EXACTLY as round 13 wrote it, even though the
// fade no longer reaches dark: these are the places the defect lived, and they
// are still the only rests long enough for the question to mean anything.
const IDLE = P.look.idleFade ?? 0.45, MAXGAP = P.look.arcMaxGap ?? 0.9;
const DARK = IDLE * Math.log(0.60 / 0.01);
const events = [];
for (const v of P.voices) {
  for (let i = 1; i < v.notes.length; i++) {
    const gap = v.notes[i].t - v.notes[i - 1].t;
    const end = v.notes[i - 1].t + v.notes[i - 1].dur;
    const rest = v.notes[i].t - end;
    if (gap > MAXGAP && rest > DARK)
      events.push({ vi: v.index, t0: v.notes[i].t, end, rest });
  }
}
console.log(`\n(R) A VOICE THROUGH A REST — ${events.length} rests in this payload longer than ` +
            `${DARK.toFixed(2)}s (which is what the OLD fade needed to put a light out)`);
if (!events.length) {
  console.log('  [BROKEN] this payload has no rest long enough for the question to mean');
  console.log('           anything — the light never had time to go out. NOT a pass.');
  process.exit(2);
}
if (R13) console.log('  [control --r13] idleFloor 0 + spawnReentry — the fly-in the user rejected, restored on purpose');
if (R19) console.log('  [control --r19] idleFloor 0 — the original extinguishing fade, restored on purpose');

const b = await puppeteer.launch({ headless: 'shell',
  args: ['--use-angle=metal', '--no-sandbox', '--allow-file-access-from-files'] });
const pg = await b.newPage();
await pg.setViewport({ width: P.width, height: P.height });
await pg.goto('file://' + path.join(HERE, 'road.html'), { waitUntil: 'networkidle0' });
await pg.evaluate(p => window.__init(p), P);
await pg.waitForFunction('window.__ready || window.__err');
const perr = await pg.evaluate(() => window.__err);
if (perr) { console.error('PAGE ERROR:', perr); await b.close(); process.exit(2); }

// ⭐ SAMPLED AT THE FILM'S OWN FRAME RATE, not at an arbitrary N. "One frame"
// is the unit every claim here is written in, so the probe has to step in it.
const rows = await pg.evaluate((evs, VOICES) => {
  const FPS = 30, out = [];
  const cometN = (S, vi) => {
    // ⚠ comet entries are keyed `vi`, not `i` — the voices array and the comets
    // array do NOT use the same field name, and reading `i` here returned
    // undefined for every voice, which would have made (R5) a hollow pass.
    const c = (S.comets || []).find(x => x.vi === vi);
    if (!c) return 0;
    return Array.isArray(c.pts) ? c.pts.length : -1;
  };
  for (const e of evs) {
    const a = e.end - 0.10, z = e.t0 + 0.10;
    let dark = 0, spawned = 0, worst = 1, worstT = 0, minRib = Infinity, minRibT = 0;
    let prev = null, first = null, strike = 1, strikeT = 0;
    for (let n = 0; n * (1 / FPS) <= z - a + 1e-9; n++) {
      const t = a + n / FPS;
      const S = window.__perf(t);
      const v = (S.voices || []).find(x => x.i === e.vi);
      const live = !!(v && v.live), env = v ? v.env : 0;
      if (!live) dark++;
      if (v && v.spawning) spawned++;
      if (first === null && live) first = { t, env };
      // the rest INTERIOR: from a frame after the note-off to a frame before the
      // next note-on. Outside it sit the release and the strike, both of which
      // are supposed to move fast.
      const inside = t > e.end + 1 / FPS && t < e.t0 - 1 / FPS;
      if (prev && inside && prev.inside && prev.env > 1e-9) {
        const r = env / prev.env;
        if (r > worst) { worst = r; worstT = t; }
      }
      if (prev && t >= e.t0 - 1e-9 && t < e.t0 + 1 / FPS && prev.env > 1e-9) {
        strike = env / prev.env; strikeT = t;
      }
      if (t > e.end && t < e.t0) {
        const rb = cometN(S, e.vi);
        if (rb < minRib) { minRib = rb; minRibT = t; }
      }
      prev = { env, live, inside };
    }
    out.push({ vi: e.vi, t0: e.t0, rest: e.rest, dark, spawned, worst, worstT,
               minRib: minRib === Infinity ? -1 : minRib, minRibT, strike, strikeT, first });
  }
  // ⭐ (R4)'s YARDSTICK: every ORDINARY strike in the film, so "the re-entry
  // strike is an ordinary strike" is a comparison rather than an opinion.
  const ord = [];
  for (const v of VOICES) {
    for (let i = 1; i < v.notes.length; i++) {
      const t0 = v.notes[i].t;
      const gap = t0 - v.notes[i - 1].t;
      const rest = t0 - (v.notes[i - 1].t + v.notes[i - 1].dur);
      if (evs.some(e => e.vi === v.index && Math.abs(e.t0 - t0) < 1e-6)) continue;
      const before = window.__perf(t0 - 1 / 30).voices.find(x => x.i === v.index);
      const after = window.__perf(t0 + 1e-4).voices.find(x => x.i === v.index);
      if (before && after && before.env > 1e-9) ord.push(after.env / before.env);
    }
  }
  ord.sort((x, y) => x - y);
  // (R6) GLOBAL SWEEP: no voice dark between its first note and its last note-off
  const glob = [];
  for (const v of VOICES) {
    const n0 = v.notes[0].t, nL = v.notes[v.notes.length - 1];
    const zEnd = nL.t + nL.dur;
    let darkAt = null, cnt = 0;
    for (let t = n0 + 1 / 30; t <= zEnd; t += 1 / 30) {
      const vv = window.__perf(t).voices.find(x => x.i === v.index);
      if (!(vv && vv.live)) { cnt++; if (darkAt === null) darkAt = +t.toFixed(3); }
    }
    glob.push({ vi: v.index, dark: cnt, at: darkAt });
  }
  return { out, ord, glob };
}, events, P.voices);
await b.close();

const { out: rows2, ord, glob } = rows;
const fails = [];
let worstAll = 1, worstRow = null, worstStrike = 1, worstStrikeRow = null, minRib = Infinity;
for (const r of rows2) {
  if (r.dark) fails.push(`(R1) voice ${r.vi} GOES DARK for ${r.dark} frame(s) during its ` +
                         `${r.rest.toFixed(2)}s rest before t=${r.t0.toFixed(3)} — it died and had to be reborn`);
  if (r.spawned) fails.push(`(R2) voice ${r.vi} SPAWNS ${r.spawned} frame(s) returning from its ` +
                            `${r.rest.toFixed(2)}s rest at t=${r.t0.toFixed(3)} — a second birth`);
  if (r.minRib >= 0 && r.minRib < 3)
    fails.push(`(R5) voice ${r.vi}'s comet drops to ${r.minRib} point(s) at t=${r.minRibT.toFixed(3)} ` +
               `during the rest — the tail vanished and restarted`);
  if (r.worst > worstAll) { worstAll = r.worst; worstRow = r; }
  if (r.strike > worstStrike) { worstStrike = r.strike; worstStrikeRow = r; }
  if (r.minRib >= 0) minRib = Math.min(minRib, r.minRib);
}
if (worstAll > STEP)
  fails.push(`(R3) voice ${worstRow.vi}'s light STEPS by ${worstAll.toFixed(2)}x in one frame at ` +
             `t=${worstRow.worstT.toFixed(3)} INSIDE the rest (limit ${STEP}x) — it should only dim smoothly`);
for (const g of glob)
  if (g.dark) fails.push(`(R6) voice ${g.vi} is DARK for ${g.dark} frame(s) between its first and ` +
                         `last note (first at t=${g.at}) — a voice that exists must stay lit`);

const q = p => ord.length ? ord[Math.min(ord.length - 1, Math.floor(p * (ord.length - 1)))] : NaN;
console.log(`  ${rows2.length} rests measured, ${rows2.reduce((a, r) => a + r.dark, 0)} dark frames, ` +
            `${rows2.reduce((a, r) => a + r.spawned, 0)} spawning frames`);
console.log(`  (R3) worst one-frame env ratio INSIDE a rest: ${worstAll.toFixed(3)}x (limit ${STEP}x)`);
console.log(`  (R5) fewest comet points during a rest: ${minRib === Infinity ? 'n/a' : minRib} (limit 3)`);
console.log(`  (R4) the strike that ENDS a rest: worst ${worstStrike.toFixed(1)}x` +
            (worstStrikeRow ? ` (voice ${worstStrikeRow.vi} at t=${worstStrikeRow.strikeT.toFixed(3)})` : '') +
            `   |   the film's ${ord.length} ORDINARY strikes: median ${q(0.5).toFixed(1)}x, ` +
            `p90 ${q(0.9).toFixed(1)}x, max ${q(1).toFixed(1)}x`);
if (worstStrike > q(1) * 1.25)
  fails.push(`(R4) the re-entry strike ${worstStrike.toFixed(1)}x is bigger than every ordinary strike ` +
             `in the film (max ${q(1).toFixed(1)}x) — it still reads as a pop, not a note`);
for (const r of rows2.slice(0, 4))
  console.log(`    voice ${r.vi} rest ${r.rest.toFixed(2)}s -> note t=${r.t0.toFixed(3)}: ` +
              `dark ${r.dark}, spawning ${r.spawned}, comet min ${r.minRib}, strike ${r.strike.toFixed(1)}x`);
if (fails.length) { for (const f of fails.slice(0, 6)) console.log(`  [ FAIL ] ${f}`); process.exit(1); }
console.log('  [ ok ] every voice stays alive, unspawned and continuous through every rest, ' +
            'and its return is an ordinary strike');
