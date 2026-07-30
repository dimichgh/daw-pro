// m23-c1 GATE — the off-clip edge cue.
//
// Every measurement is made on a CROP of the piano-roll region, taken from the
// start: the arrange playhead moves regardless of what the roll does, and
// whole-window hashing has already produced one false negative on this exact
// surface. Every crop's real pixel dimensions are asserted before its numbers
// are trusted, because a silently-failed crop reproduces that false negative.
//
// Agreement between the note grid and the velocity lane is measured, not
// eyeballed: both bands are probed with IDENTICAL x windows, so the cyan-ink
// column runs they report are directly comparable. If the two bands placed the
// cue at different x the runs would differ.
//
// CLASS 1 since m23-ac-3b-3. Setup is no longer a human's job:
//   node scripts/gates/m23c1-offclip-cue.mjs
// The gate builds the app, builds the column probe, and launches its own staging
// app on 17695 (never 17600, the user's live app). Both binaries it measures
// through are now built by the run that measures — this gate had TWO provenance
// gaps, not one, because the probe was also compiled by hand "once".
import fs from "fs";
import { execFileSync, spawnSync } from "child_process";
import { ROOT, buildOrAbort, startStaging, stopStaging, connect, sleep } from "./_staging.mjs";

const GATE = "m23c1";                       // names the pidfile + staging out dir
const OUT = process.env.M23C1_OUT || "/tmp/m23c1";
const PROBE = process.env.M23C1_PROBE || "/tmp/m23c1-probe";
fs.mkdirSync(OUT, { recursive: true });
// NOTE: OUT is deliberately left outside /tmp/daw-gate-out, where every other
// gate's artefacts live, so this gate's captures stay where its history is. The
// pidfile therefore sits in a DIFFERENT tree from the captures — surprising, but
// changing it would orphan the comparison baselines.

// The 600 s self-kill. Since m23-bd the harness tears the staging app down on
// `exit`, so this path — the one that fires precisely when the gate has HUNG —
// no longer leaks the app it was driving.
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);

buildOrAbort({ label: "building staging binary (m23c1)…" });
// Rebuild the cyan-column probe every run, for the same reason the app is built
// every run: a stale probe measures the previous build's idea of the pixels.
// m23t-baroperand already does this with the same probe; the header here used to
// ask a human to compile it once by hand.
const probeBuild = spawnSync("swiftc", ["-O", "-o", PROBE,
                             "scripts/probes/m23c1-cyan-column-probe.swift"],
                             { cwd: ROOT, stdio: "inherit" });
if (probeBuild.status !== 0) {
  console.log("ABORT: probe compile failed — the pixel legs would measure a stale probe");
  process.exit(2);
}
startStaging({ gate: GATE });

// ── crop windows, in CAPTURE pixels (window 1400x1000 logical @2x = 2800x2000)
// x windows: shared by both bands so their numbers are comparable.
const W = {
  LEAD:    { x: 100,  w: 280 },   // band leading edge; clear of the notes (local beat 4+)
  LINEEND: { x: 600,  w: 180 },   // where the clip-END playhead line falls (local beat 8)
  TRAIL:   { x: 2450, w: 340 },   // band trailing edge
};
// y slices: the row each band draws its direction pill in. Different per band
// (they are different bands), identical x — which is the point.
const BAND = {
  grid: { y: 875,  h: 60 },
  vel:  { y: 1552, h: 56 },
};
// A tall grid slice below the pill, where the wash is unoccluded — this is where
// the proximity ramp is measured.
const WASH = { x: 120, y: 950, w: 300, h: 500 };

function probe(png, tag, x, y, w, h, threshold) {
  const out = `${OUT}/crop-${tag}.png`;
  const raw = execFileSync(PROBE, [png, out, String(x), String(y), String(w), String(h), String(threshold)])
    .toString();
  const kv = Object.fromEntries(raw.trim().split("\n").map((l) => l.split("=")));
  // HARD dimension assertion: a silently-failed crop is the known false-negative mode.
  const expect = `${w}x${h}`;
  if (kv.dims !== expect) throw new Error(`crop ${tag}: dims ${kv.dims} != ${expect}`);
  kv.hot = Number(kv.hotColumns);
  kv.peakN = Number(kv.peak);
  kv.runList = kv.runs === "-" ? [] : kv.runs.split(",");
  kv.span = kv.runList.length
    ? Number(kv.runList[kv.runList.length - 1].split("-")[1]) - Number(kv.runList[0].split("-")[0])
    : 0;
  kv.path = out;
  return kv;
}

let nextId = 1; const pending = new Map();
const req = (ws, command, params = {}) => {
  const id = String(nextId++);
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject, command });
    ws.send(JSON.stringify({ id, command, params }));
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, 25000);
  });
};
const ws = await connect();   // 40x1 s, and refuses port 17600 outright
ws.onmessage = (ev) => {
  let m; try { m = JSON.parse(ev.data); } catch { return; }
  const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
  if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
  else e.resolve(m.result ?? m);
};

// ── fixture ───────────────────────────────────────────────────────────────
await req(ws, "project.new", { discardChanges: true });
await req(ws, "debug.windowFrame", { width: 1400, height: 1000 });
await req(ws, "debug.panelDensity", { panel: "pianoRoll", mode: "pro" });
const tr = await req(ws, "track.add", { name: "Playhead Probe", kind: "instrument" });
const trackId = tr.id ?? tr.track?.id;
// Notes deliberately start at clip-local beat 4, so the LEAD window is clear of
// note bodies in the grid AND of velocity stems in the lane — the two bands can
// then be compared on the cue alone.
const notes = [4, 5, 6].map((b, i) => ({
  pitch: [60, 64, 67][i], startBeat: b, lengthBeats: 0.9, velocity: 100,
}));
const clip = await req(ws, "clip.addMIDI", { trackId, atBeat: 16, lengthBeats: 8, notes });
const clipId = clip.id ?? clip.clip?.id;
console.log(`fixture: clip @16 len 8 (project beats 16...24), notes at local 4/5/6 — ${clipId}\n`);

const STATES = [
  { tag: "S1-before-far",   beat: 0,    note: "4 bars BEFORE the clip" },
  { tag: "S2-before-near",  beat: 15,   note: "1 beat BEFORE — proximity ramp near max" },
  { tag: "S3-edge-start",   beat: 16,   note: "EXACT start edge — line, no cue" },
  { tag: "S4-inside",       beat: 19.5, note: "inside — line, no cue" },
  { tag: "S5-edge-end",     beat: 24,   note: "EXACT end edge — line, no cue" },
  { tag: "S6-after-near",   beat: 25,   note: "1 beat AFTER" },
  { tag: "S7-after-far",    beat: 40,   note: "4 bars AFTER" },
];

const results = {};
for (const st of STATES) {
  await req(ws, "transport.seek", { beats: st.beat });
  await sleep(450);
  const cap = await req(ws, "debug.captureUI", { path: `${OUT}/${st.tag}.png`, selectClip: clipId });
  if (cap.width !== 2800 || cap.height !== 2000) throw new Error(`capture size ${cap.width}x${cap.height}`);
  const r = { note: st.note, beat: st.beat, full: cap.path, band: {} };
  for (const [bandName, b] of Object.entries(BAND)) {
    r.band[bandName] = {};
    for (const [winName, win] of Object.entries(W)) {
      r.band[bandName][winName] = probe(cap.path, `${st.tag}-${bandName}-${winName}`,
                                        win.x, b.y, win.w, b.h, 8.0);
    }
  }
  r.wash = probe(cap.path, `${st.tag}-wash`, WASH.x, WASH.y, WASH.w, WASH.h, 2.0);
  results[st.tag] = r;
  const g = r.band.grid, v = r.band.vel;
  console.log(`${st.tag}  beat ${st.beat}  — ${st.note}`);
  console.log(`   grid LEAD runs=${g.LEAD.runs}  LINEEND runs=${g.LINEEND.runs}  TRAIL runs=${g.TRAIL.runs}`);
  console.log(`   vel  LEAD runs=${v.LEAD.runs}  LINEEND runs=${v.LINEEND.runs}  TRAIL runs=${v.TRAIL.runs}`);
  console.log(`   wash peak=${r.wash.peak} runs=${r.wash.runs}`);
}

// ── Simple mode: the velocity lane does not exist (Simple is the DEFAULT
// density, so it is the mode the user's report most likely came from). The
// grid cue must still be there, and the law's wording is "every band that is
// present", not "both bands".
await req(ws, "debug.panelDensity", { panel: "pianoRoll", mode: "simple" });
await req(ws, "transport.seek", { beats: 0 });
await sleep(500);
const simpleCap = await req(ws, "debug.captureUI", { path: `${OUT}/S8-simple.png`, selectClip: clipId });
const simple = {
  grid: probe(simpleCap.path, "S8-simple-grid-LEAD", W.LEAD.x, BAND.grid.y, W.LEAD.w, BAND.grid.h, 8.0),
  // Where the velocity band WAS in Pro: in Simple the grid occupies it, so this
  // is a check that nothing cue-like is orphaned down there.
  velSlot: probe(simpleCap.path, "S8-simple-velslot-LEAD", W.LEAD.x, BAND.vel.y, W.LEAD.w, BAND.vel.h, 8.0),
};
console.log(`\nS8-simple  beat 0 — Simple density (no velocity lane)`);
console.log(`   grid LEAD runs=${simple.grid.runs}`);
console.log(`   ex-velocity slot runs=${simple.velSlot.runs}`);
await req(ws, "debug.panelDensity", { panel: "pianoRoll", mode: "pro" });

// ── assertions ────────────────────────────────────────────────────────────
const checks = [];
const check = (name, ok, detail) => { checks.push({ name, ok, detail }); };

// A pill reads as SEVERAL glyph runs spanning ~100px; a bare playhead line reads
// as ONE run well under 40px wide. That difference is the double-draw detector.
const isPill = (m) => m.runList.length >= 4 && m.span >= 70;
const isLineOnly = (m) => m.runList.length >= 1 && m.runList.length <= 2 && m.span < 40;
const isEmpty = (m) => m.runList.length === 0;

// Band agreement is compared on the ink's OUTER BOUNDS with a 4 px tolerance,
// not on exact run strings. Calibration for that tolerance is empirical and
// comes from the surface itself: S4 measures the pre-existing PLAYHEAD LINE,
// which both bands draw from the identical `lineX` value and so is known-
// identical by construction — it still reads 2 px apart, because the two bands
// have different slice heights and the line's glow crosses the ink threshold at
// slightly different columns. 4 px (2 pt) is under half a glyph and far under
// any real placement difference (a scroller-width divergence would be ~30 px).
const bounds = (m) => m.runList.length
  ? [Number(m.runList[0].split("-")[0]), Number(m.runList[m.runList.length - 1].split("-")[1])]
  : [NaN, NaN];
const AGREE_TOL = 4;
function agree(g, v) {
  if (g.runList.length !== v.runList.length) return false;
  const [gs, ge] = bounds(g), [vs, ve] = bounds(v);
  return Math.abs(gs - vs) <= AGREE_TOL && Math.abs(ge - ve) <= AGREE_TOL;
}
const agreeDetail = (g, v) => `grid [${bounds(g).join("..")}] ${g.runList.length} runs | ` +
                              `vel [${bounds(v).join("..")}] ${v.runList.length} runs`;

for (const tag of ["S1-before-far", "S2-before-near"]) {
  const r = results[tag];
  check(`${tag}: grid shows the leading cue`, isPill(r.band.grid.LEAD), r.band.grid.LEAD.runs);
  check(`${tag}: velocity shows the leading cue`, isPill(r.band.vel.LEAD), r.band.vel.LEAD.runs);
  check(`${tag}: BANDS AGREE on the cue's x`, agree(r.band.grid.LEAD, r.band.vel.LEAD),
        agreeDetail(r.band.grid.LEAD, r.band.vel.LEAD));
  check(`${tag}: nothing at the trailing edge`,
        isEmpty(r.band.grid.TRAIL) && isEmpty(r.band.vel.TRAIL),
        `grid ${r.band.grid.TRAIL.runs} | vel ${r.band.vel.TRAIL.runs}`);
}
for (const tag of ["S6-after-near", "S7-after-far"]) {
  const r = results[tag];
  check(`${tag}: grid shows the trailing cue`, isPill(r.band.grid.TRAIL), r.band.grid.TRAIL.runs);
  check(`${tag}: velocity shows the trailing cue`, isPill(r.band.vel.TRAIL), r.band.vel.TRAIL.runs);
  check(`${tag}: BANDS AGREE on the TRAILING x`, agree(r.band.grid.TRAIL, r.band.vel.TRAIL),
        agreeDetail(r.band.grid.TRAIL, r.band.vel.TRAIL));
  check(`${tag}: nothing at the leading edge`,
        isEmpty(r.band.grid.LEAD) && isEmpty(r.band.vel.LEAD),
        `grid ${r.band.grid.LEAD.runs} | vel ${r.band.vel.LEAD.runs}`);
}
// The two inclusive edges: the LINE draws and the cue must NOT double-draw.
{
  const r = results["S3-edge-start"];
  check("S3 start edge: grid shows the LINE only, no pill", isLineOnly(r.band.grid.LEAD), r.band.grid.LEAD.runs);
  check("S3 start edge: velocity shows the LINE only, no pill", isLineOnly(r.band.vel.LEAD), r.band.vel.LEAD.runs);
  check("S3 start edge: bands agree", agree(r.band.grid.LEAD, r.band.vel.LEAD),
        agreeDetail(r.band.grid.LEAD, r.band.vel.LEAD));
  check("S3 start edge: trailing edge clean",
        isEmpty(r.band.grid.TRAIL) && isEmpty(r.band.vel.TRAIL),
        `grid ${r.band.grid.TRAIL.runs} | vel ${r.band.vel.TRAIL.runs}`);
}
{
  const r = results["S5-edge-end"];
  check("S5 end edge: grid shows the LINE at the clip end", isLineOnly(r.band.grid.LINEEND), r.band.grid.LINEEND.runs);
  check("S5 end edge: velocity shows the LINE at the clip end", isLineOnly(r.band.vel.LINEEND), r.band.vel.LINEEND.runs);
  check("S5 end edge: bands agree", agree(r.band.grid.LINEEND, r.band.vel.LINEEND),
        agreeDetail(r.band.grid.LINEEND, r.band.vel.LINEEND));
  check("S5 end edge: NO trailing cue (the cue must not appear one beat early)",
        isEmpty(r.band.grid.TRAIL) && isEmpty(r.band.vel.TRAIL),
        `grid ${r.band.grid.TRAIL.runs} | vel ${r.band.vel.TRAIL.runs}`);
  check("S5 end edge: NO leading cue",
        isEmpty(r.band.grid.LEAD) && isEmpty(r.band.vel.LEAD),
        `grid ${r.band.grid.LEAD.runs} | vel ${r.band.vel.LEAD.runs}`);
}
{
  const r = results["S4-inside"];
  check("S4 inside: grid shows the LINE only", isLineOnly(r.band.grid.LEAD), r.band.grid.LEAD.runs);
  check("S4 inside: velocity shows the LINE only", isLineOnly(r.band.vel.LEAD), r.band.vel.LEAD.runs);
  check("S4 inside: bands agree (this is the TOLERANCE CALIBRATION case — the pre-existing line)",
        agree(r.band.grid.LEAD, r.band.vel.LEAD), agreeDetail(r.band.grid.LEAD, r.band.vel.LEAD));
  check("S4 inside: no cue at either edge",
        isEmpty(r.band.grid.TRAIL) && isEmpty(r.band.vel.TRAIL),
        `trail grid ${r.band.grid.TRAIL.runs} | vel ${r.band.vel.TRAIL.runs}`);
}
// Proximity ramp: the wash is measurably brighter one beat out than four bars out.
{
  const far = Number(results["S1-before-far"].wash.peak);
  const near = Number(results["S2-before-near"].wash.peak);
  check("proximity ramp brightens the wash as the transport approaches",
        near > far * 1.5, `far(4 bars)=${far} near(1 beat)=${near}`);
}
// Simple mode.
check("S8 Simple: the grid still shows the cue", isPill(simple.grid), simple.grid.runs);
check("S8 Simple: no SECOND pill in the y the velocity lane occupies in Pro (the grid extends there, so its own wash is expected)",
      !isPill(simple.velSlot), simple.velSlot.runs);

// Distinctness: the off-clip frames are NOT byte-identical any more (case B of
// the original repro produced three identical frames).
{
  const shas = ["S1-before-far", "S2-before-near", "S6-after-near", "S7-after-far"]
    .map((t) => results[t].band.grid.LEAD.sha + results[t].band.grid.TRAIL.sha);
  check("off-clip frames are all DISTINCT (the original repro's byte-identical case B)",
        new Set(shas).size === shas.length, shas.join(" "));
}

console.log("\n=== GATE ===");
let failed = 0;
for (const c of checks) {
  if (!c.ok) failed++;
  console.log(`${c.ok ? "PASS" : "FAIL"}  ${c.name}\n        ${c.detail}`);
}
fs.writeFileSync(`${OUT}/gate.json`, JSON.stringify({ results, simple, checks }, null, 2));
console.log(`\n${checks.length - failed}/${checks.length} checks passed`);
clearTimeout(killer);
stopStaging(GATE);   // SIGTERMs by exact pid AND releases our session.lock
ws.close();
process.exit(failed === 0 ? 0 : 1);
