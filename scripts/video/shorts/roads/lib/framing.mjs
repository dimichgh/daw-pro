#!/usr/bin/env node
// ⛔ THE PLAYHEAD MUST NOT LEAVE FRAME. That is the unambiguous half of the
// user's note on the reverse angle -- "playhead moves faster out of screen.
// camera needs to move slower and track position of playhead" -- and nothing in
// the suite measured it. The observer measured the symptom from the outside:
// bright pixels on the very BOTTOM ROW of frame in 35.3 % of approach frames
// and 32.1 % of approach-cool, against 20.3 % for landscape, with the playheads
// half out of frame at t=6.600 and t=11.500.
//
// This measures the cause directly: every LIVE playhead's projected position,
// every frame, must sit inside the frame with a margin. Cheap (no screenshots,
// projection only) so it can run on every cut.
//
// ⚠ IT IS NOT A LOOK GATE. It cannot tell tight tracking from loose tracking;
// those are laddered for the user to pick. It only says whether the subject is
// in the shot.
//
// CONTROL: --fixedrate forces the take back to the constant-rate recede that
// was measured leaving frame. Must fail.
//
// Usage: node framing.mjs <payload.json> [--fixedrate]
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


const payloadPath = path.resolve(process.argv[2]);
const FIXED = process.argv.includes('--fixedrate');
// ⚠ FORWARD REFERENCE (2026-09-08): the paragraph below calls `--narrowlens`
// "the control that does bite". It bites on the LONG FILM. It is INERT on
// 07-bach-short — 4 fovs shrunk and the gate still passes, because that camera
// is close enough to keep the subject centred. Use `--plantcam` (further down)
// for a control that fires on every cut measured so far.
// ⛔⛔ THE EXISTING CONTROL IS INERT ON A JOURNEY TAKE. `--fixedrate` deletes
// `take.track`, but the journey branch reads trackZ/trackX unconditionally — so
// on the long film that control CANNOT FAIL, which is the exact defect this
// suite keeps finding in itself. `--narrowlens` is the control that does bite:
// it shrinks every journey segment's fov to 35 % (and the keyframe camera's
// too), which must push the lateral band out of frame.
const NARROW = process.argv.includes('--narrowlens');
const P = JSON.parse(fs.readFileSync(payloadPath, 'utf8'));
// ⭐ THE CONTROL IS APPLIED TO THE PAYLOAD BEFORE __init, NOT POKED INTO THE
// PAGE AFTERWARDS. The track is built once at init from the take's own fields,
// so a post-init edit would be read by nothing and the "control" would quietly
// re-measure the fixed film -- a control that cannot fail is the exact failure
// this round was called on.
if (FIXED) {
  for (const k of Object.keys(P.takes || {}))
    if (P.takes[k] && typeof P.takes[k] === 'object') delete P.takes[k].track;
  console.log('  [control] `track` stripped from every take before init — this is the constant-rate recede that was measured leaving frame');
}
if (NARROW) {
  let n = 0;
  for (const k of Object.keys(P.takes || {})) {
    const tk = P.takes[k];
    if (!tk || typeof tk !== 'object') continue;
    if (Array.isArray(tk.segments)) for (const sg of tk.segments) { if (sg.fov) { sg.fov *= 0.35; n++; } }
    if (tk.fov) { tk.fov *= 0.35; n++; }
  }
  for (const kf of (P.camera || [])) if (kf.fov) { kf.fov *= 0.35; n++; }
  if (!n) { console.error('  [BROKEN] --narrowlens found no fov to shrink — the control did nothing'); process.exit(2); }
  console.log(`  [control] every fov shrunk to 35% (${n} of them) — the subject MUST leave frame`);
}
// ⛔⛔ --narrowlens IS NOT UNIVERSAL, MEASURED 2026-09-08. On 07-bach-short it
// shrinks 4 fovs and the gate still passes: that camera is close enough that a
// 65 % narrower lens keeps every subject near the centre.
// ⛔⛔ AND MOVING THE CAMERA IS NOT A CONTROL EITHER — I tried it and it made
// the gate report 0 out of frame on 03 AND 08, i.e. WORSE than inert. Both
// journey cameras AIM at the focus point, so sliding `x`/`side` sideways just
// re-aims and the subject stays centred. A control has to break the AIM.
// `--plantcam` therefore swings the aim 60 degrees off (keyframe path:
// `look.camYawAdd`, the only lateral knob that path reads; journey path: every
// segment's `aimX`). Everything must leave frame, resting voices included.
const PLANT = process.argv.includes('--plantcam');
if (PLANT) {
  let n = 0;
  P.look = P.look || {};
  P.look.camYawAdd = (P.look.camYawAdd ?? 0) + 60; n++;
  for (const k of Object.keys(P.takes || {})) {
    const tk = P.takes[k];
    if (!tk || typeof tk !== 'object' || !Array.isArray(tk.segments)) continue;
    for (const sg of tk.segments) { sg.aimX = (sg.aimX ?? 0) + 60; n++; }
  }
  // ⚠ `camYawAdd` always increments, so `n` can never be 0 — and on a JOURNEY
  // film that field is read by nothing (road.html:1256 is the keyframe path
  // only). A journey take with no segments would therefore "run" this control
  // and change nothing. Require a segment aim on the journey path explicitly.
  const journey = Object.values(P.takes || {}).some(t => t && Array.isArray(t.segments) && t.segments.length);
  const usesJourney = journey && (P.look?.take && P.takes?.[P.look.take]?.segments?.length);
  if (usesJourney && n < 2) {
    console.error('  [BROKEN] --plantcam moved only camYawAdd on a JOURNEY take, which does not read it — the control did nothing');
    process.exit(2);
  }
  console.log(`  [control] aim swung 60 degrees / 60 units off the subject (${n} fields) — EVERY playhead, resting ones included, must leave frame`);
}
const HERE = path.dirname(new URL(import.meta.url).pathname);
const W = P.width ?? 1080, H = P.height ?? 1920;
const FPS = 30;
const MARGIN = Number(process.env.FRAMING_MARGIN ?? 0.035);   // fraction of the frame
const ALLOW = Number(process.env.FRAMING_ALLOW ?? 0.04);      // tolerated fraction of frames

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

const total = P.total ?? 14;
// ⛔ ROUND 7: THIS WALKED 360 OF 414 FRAMES. `total` is the MUSIC's length
// (12.0175 s) while the film is rendered to `renderSeconds` (13.8 s), so THE
// LAST 54 FRAMES -- the coast-to-a-stop, where a tracking camera is most likely
// to drift off its subject -- were never examined at all. The gate reported a
// clean pass over a window that excluded the risky part.
// ⚠ THE PAYLOAD DOES NOT CARRY renderSeconds -- only `total`, the MUSIC's
// length. The film is longer (the camera coasts to a stop after the last note),
// so the window is extended by the coast rather than left at the music's end.
const RSEC = Number(process.env.FRAMING_SECONDS ?? 0)
          || (P.renderSeconds ?? (total + (P.look?.coastTau ?? 0.8) * 2.5));
const N = Math.floor(RSEC * FPS);
// ⭐ A WINDOW, so one segment of a 3-minute journey can be laddered without
// paying for 5400 projections. The SHIPPING run leaves both unset and walks the
// whole film — a windowed pass is a tuning instrument, never a verdict.
const T0 = Number(process.env.FRAMING_FROM ?? 0);
const T1 = Number(process.env.FRAMING_TO ?? 0) || Infinity;
if (T0 > 0 || T1 < Infinity)
  console.log(`  [window] ONLY t=${T0}..${T1 === Infinity ? RSEC.toFixed(2) : T1} — this is a tuning pass, not a verdict`);
// ⛔⛔ THE FILTER BELOW IS THE BUG THIS GATE SHIPPED WITH, AND IT IS WHY THIS
// KNOB EXISTS. `env > 0.25` was meant to skip voices that are barely lit. But a
// voice AT REST sits at `idleFloor` = 0.13 (road.html:~1651), which is BELOW
// 0.25 — so every resting playhead was invisible to this gate, and a rest is
// exactly when a road stops being tracked and drifts off the edge. MEASURED on
// 03-moonlight-long: melody voice 0 at t=145.0 is `live:true`, env 0.130,
// sx = -45 px, `onScreen:false` — off the LEFT edge of a 1920-wide frame, for
// t=136.5..153.0 — while this gate reported 0 of 24,324 playhead-frames out of
// frame. Default kept at 0.25 so an old verdict still reproduces; set
// FRAMING_ENVMIN=0.011 (just above road.html's own `live` cutoff of 0.01) to
// measure what the gate has always been blind to.
const ENVMIN = Number(process.env.FRAMING_ENVMIN ?? 0.25);
if (ENVMIN !== 0.25) console.log(`  [envmin] counting every playhead with env > ${ENVMIN} (default 0.25 SKIPS resting voices at idleFloor 0.13)`);
let frames = 0, bad = [], live = 0, worst = 0;
let restBad = [], restLive = 0;
const STRICT = process.env.FRAMING_STRICT === '1';
for (let n = 0; n < N; n++) {
  const t = n / FPS;
  if (t < T0 || t > T1) continue;
  const pos = await pg.evaluate(tt => window.__screenPos(tt), t);
  const alive = pos.filter(v => v.live && v.env > ENVMIN);
  // ⭐ THE SECOND POPULATION, AND THE WHOLE POINT OF THIS ROUND: voices that are
  // LIVE by road.html's own definition (env > 0.01) but sit below this gate's
  // brightness filter — i.e. AT REST, at idleFloor 0.13. They were counted by
  // nothing. They are measured here ALWAYS and reported on their own line, so
  // the gate can never again print `0 out of frame` about a film in which a
  // road is visibly dark. They do not change the verdict unless FRAMING_STRICT=1.
  const resting = pos.filter(v => v.live && v.env <= ENVMIN);
  for (const v of resting) {
    restLive++;
    const fx = v.sx / W, fy = v.sy / H;
    const out = Math.max(MARGIN - fx, fx - (1 - MARGIN), MARGIN - fy, fy - (1 - MARGIN));
    if (!v.onScreen || out > 0) restBad.push({ n, i: v.i, env: v.env, core: v.envCore, fx: +fx.toFixed(3), fy: +fy.toFixed(3) });
  }
  if (!alive.length) continue;
  frames++;
  for (const v of alive) {
    live++;
    const fx = v.sx / W, fy = v.sy / H;
    const out = Math.max(MARGIN - fx, fx - (1 - MARGIN), MARGIN - fy, fy - (1 - MARGIN));
    if (!v.onScreen || out > 0) {
      worst = Math.max(worst, out);
      bad.push({ n, i: v.i, fx: +fx.toFixed(3), fy: +fy.toFixed(3) });
    }
  }
}
if (pageErr) { console.error('PAGE ERROR:', pageErr); await b.close(); process.exit(2); }
await b.close();

console.log(`\nFRAMING — every live playhead inside the frame, margin ${(MARGIN*100).toFixed(1)}%, ${frames} frames, ${live} playhead-frames`);
if (!frames) { console.log('  [BROKEN] no frame had a live playhead — nothing was measured'); process.exit(2); }
const frac = bad.length / live;
const uniq = [...new Set(bad.map(x => x.n))];
console.log(`  out of frame: ${bad.length} playhead-frames (${(frac*100).toFixed(1)}%) across ${uniq.length} distinct frames` +
            (bad.length ? `, worst overshoot ${(worst*100).toFixed(1)}% of the frame` : ''));
// ⭐ WHERE, not just how many. On a 3-minute journey "1.3 %" says nothing about
// which move is broken; contiguous runs of offending frames name the segment.
if (bad.length) {
  const ns = [...new Set(bad.map(x => x.n))].sort((a, b) => a - b);
  const runs = [];
  for (const n of ns) {
    const last = runs[runs.length - 1];
    if (last && n - last[1] <= 3) last[1] = n; else runs.push([n, n]);
  }
  console.log('  clusters (t seconds): ' + runs.map(r =>
    `${(r[0]/FPS).toFixed(2)}-${(r[1]/FPS).toFixed(2)} (${r[1]-r[0]+1}f)`).join('  '));
}
if (bad.length) console.log(`  first offenders: ` + bad.slice(0, 6).map(x => `n=${x.n} v${x.i} (${x.fx},${x.fy})`).join('  '));
// ⛔⛔ THE RESTING-VOICE REPORT. Printed on EVERY run, pass or fail.
if (restLive) {
  const rf = restBad.length / restLive;
  const line = `  resting playheads (live, env <= ${ENVMIN} — the population this gate ignored until 2026-09-08): ` +
               `${restBad.length} of ${restLive} out of frame (${(rf*100).toFixed(1)}%)`;
  console.log(line);
  if (restBad.length) {
    const ns = [...new Set(restBad.map(x => x.n))].sort((a, b) => a - b);
    const runs = [];
    for (const n of ns) { const l = runs[runs.length-1]; if (l && n - l[1] <= 3) l[1] = n; else runs.push([n, n]); }
    console.log('  resting clusters (t seconds): ' + runs.map(r =>
      `${(r[0]/FPS).toFixed(2)}-${(r[1]/FPS).toFixed(2)} (${r[1]-r[0]+1}f)`).join('  '));
    // ⭐⭐ TWO ENVELOPES, AND READING ONLY ONE UNDERSTATES THE DAMAGE. `env`
    // drives the lamp and the comet; `envCore` drives the DISK. Under
    // coreSteady:1 they DIVERGE AT REST — MEASURED on 03 at t=144/145/146, a
    // resting voice reads env 0.130 / envCore 0.600, i.e. a FULL-BRIGHTNESS DISK
    // (identical to a sounding voice's 0.6) wearing a dim lamp. So what left the
    // frame in 03's 18.3 s run is a bright disk, not a dim dot.
    // ⚠ The Bach clusters are genuinely different: at t=134.2-134.4 both films
    // read env 0.0127-0.0294 AND envCore 0.0127-0.0294 — the terminal fade, on
    // its way to the 0.01 `live` cutoff, invisible in both channels.
    // ⚠ 0.10 below is a CHOSEN CUT, not a measured visibility floor. Nobody has
    // measured the brightness at which a viewer stops seeing a disk; the cut
    // separates the two populations above, and the env/core pair is printed so
    // the classification can be checked rather than inherited.
    const es = restBad.map(x => x.env);
    const cs = restBad.map(x => x.core).filter(x => x !== undefined && x !== null);
    console.log(`  offending env range ${Math.min(...es).toFixed(3)}..${Math.max(...es).toFixed(3)}` +
                (cs.length ? `, envCore range ${Math.min(...cs).toFixed(3)}..${Math.max(...cs).toFixed(3)} (the DISK)` : ''));
    const vis = restBad.filter(x => x.env >= 0.10 || (x.core ?? 0) >= 0.10);
    console.log(`  of those, ${vis.length} are at or above a CHOSEN 0.10 cut on either envelope — bright enough that their absence shows`);
    // ⭐⭐ USER RULING 2026-09-08 — THIS IS NOT A DEFECT, AND THE GATE MUST SAY SO.
    // Shown the 03 frame where the Melody road is dark with its disk off frame
    // left at full envCore, the user said: "all 3 images are good... it makes it
    // more natural that camera in 2nd image is looking to the right." So this
    // line REPORTS and never fails by default. Do not flip STRICT on without a
    // fresh ruling; do not re-open 03. A MEASURED ANOMALY IS NOT A DEFECT.
    console.log('  A resting playhead off frame means that road carries no light while its voice rests.');
    console.log('  ⭐ RULED NOT A DEFECT by the user 2026-09-08 ("more natural that the camera is looking' +
                ' to the right") — this is REPORTED so nobody finds out by accident, not failed.' +
                (STRICT ? ' FRAMING_STRICT=1 is on, so it WILL fail.' : ''));
  }
}
if (STRICT && restBad.length) {
  console.log(`  [ FAIL ] (strict) ${restBad.length} resting playhead-frames are out of frame`);
  process.exit(1);
}
if (frac > ALLOW) {
  console.log(`  [ FAIL ] the subject leaves frame in ${(frac*100).toFixed(1)}% of playhead-frames (limit ${(ALLOW*100).toFixed(1)}%) — the camera is not tracking it`);
  process.exit(1);
}
console.log('  [ ok ] the playhead stays in frame');
