#!/usr/bin/env node
// ⛔ THE GATE FOR THE MISSING-NOTEHEAD BUG (round 2, note 3) AND, SINCE ROUND 4,
// FOR THE WRONG-ROAD BUG THAT MULTIPLE STAVES MAKE POSSIBLE.
//
// The user reported "some notes are not there, the balls bounce off empty
// space". The cause was two names for one concept: prep selected landing marks
// on `tr.roadSide` while the fireballs were selected on `tr.roadDrum`, so no
// song ever produced a mark and every drum hit landed on bare paper.
//
// This asserts the two BOTH WAYS, on the payload the scene actually renders:
//   every thing that LANDS has a mark at its exact spot, and
//   every mark has a thing that lands on it.
// A count check alone would pass 24 marks in the wrong 24 places, so the
// comparison is on (road, t, x) keys, not on lengths.
//
// ⭐⭐ ROUND 4 ADDS THE CHECK THE SYNC GATE STRUCTURALLY CANNOT DO.
// sync.py compares a brightness FLASH against an audio ONSET. It does not know
// where on screen the flash was drawn, so with one road it could not see a
// note drawn at the wrong PITCH, and with three roads it cannot see a note
// drawn on the wrong INSTRUMENT'S STAFF — a bass note lighting up on the piano
// road is perfectly in time and completely wrong. Two structural asserts close
// that:
//   (4) BAND CONTAINMENT — every notehead, every ball and every drum landing
//       lies inside its OWN road's band [x0-halfW, x0+halfW].
//   (5) BAND DISJOINTNESS — no two roads' bands overlap, so containment is a
//       statement about identity and not just about a range that happens to
//       include everything.
// Together they mean a note can only be drawn where its own instrument's staff
// is. What they still cannot see is the PIXELS; lib/roadpix.mjs photographs
// the film for that, and this file is its payload-level counterpart.
//
// Usage:  node marks.mjs <payload.json> [--drop-a-mark] [--cross-road]
//   --drop-a-mark  deletes one mark before checking, to prove (2) reddens.
//   --cross-road   moves one voice's notes onto the NEXT road's band without
//                  changing a single time, to prove (4) reddens — i.e. the
//                  exact defect that is perfectly in sync and perfectly wrong.
import { readFileSync } from 'node:fs';

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


const path = process.argv[2];
if (!path) { console.error('usage: marks.mjs <payload.json> [--drop-a-mark] [--cross-road]'); process.exit(2); }
const P = JSON.parse(readFileSync(path, 'utf8'));

// ⚠ THE KEY CARRIES THE ROAD. Without it two roads that happen to share an x
// offset would satisfy each other's asserts, and the whole point of the round-4
// gate would evaporate silently.
const K = (r, t, x) => `${r}|${t.toFixed(4)}@${x.toFixed(4)}`;
const roads = P.roads || [{ index: 0, name: '(single)', x0: 0, halfW: 1e9 }];
const R = i => roads[i] || roads[0];

let voices = P.voices.map(v => ({ ...v, notes: v.notes.slice() }));
if (process.argv.includes('--cross-road')) {
  // move ONE voice's notes onto another road's band. Times are untouched, so
  // sync.py stays perfectly green — that is exactly what makes this the right
  // control for a check sync cannot perform.
  const vi = voices.findIndex(v => roads.length > 1);
  const from = R(voices[vi].road ?? 0), to = R(((voices[vi].road ?? 0) + 1) % roads.length);
  const d = to.x0 - from.x0;
  voices[vi] = { ...voices[vi], notes: voices[vi].notes.map(n => ({ ...n, x: n.x + d })) };
  console.log(`  [control] moved voice ${vi} from road "${from.name}" onto "${to.name}" ` +
              `(x shifted by ${d.toFixed(2)}); every ONSET TIME is unchanged`);
}

// ---- 1. every ROAD note (what the voice lights land on) has a notehead ------
const heads = new Map();
for (const n of P.notes) heads.set(K(n.road ?? 0, n.t, n.x), (heads.get(K(n.road ?? 0, n.t, n.x)) || 0) + 1);

const landings = [];
for (const v of voices) for (const n of v.notes)
  landings.push({ t: n.t, x: n.x, pitch: n.pitch, road: v.road ?? 0 });

const missingHead = landings.filter(l => !heads.has(K(l.road, l.t, l.x)));

// ---- 2. every DRUM hit has a side mark at its own signed lane ---------------
let side = P.side.slice();
if (process.argv.includes('--drop-a-mark')) {
  const gone = side.pop();
  console.log(`  [control] deliberately dropped the mark at t=${gone.t.toFixed(3)} u=${gone.u}`);
}
const marks = new Set(side.map(s => K(s.road ?? 0, s.t, s.u)));
const missingMark = P.drums.filter(d => !marks.has(K(d.road ?? 0, d.t, d.lane)));

// ---- 3. and no mark that nothing lands on ----------------------------------
const lands = new Set(P.drums.map(d => K(d.road ?? 0, d.t, d.lane)));
const orphanMark = side.filter(s => !lands.has(K(s.road ?? 0, s.t, s.u)));
const usedHeads = new Set(landings.map(l => K(l.road, l.t, l.x)));
const orphanHead = P.notes.filter(n => !usedHeads.has(K(n.road ?? 0, n.t, n.x)));

// ---- 4. BAND CONTAINMENT: nothing is drawn on another instrument's staff ----
const outside = [];
const check = (what, road, x, extra) => {
  const rd = R(road), half = rd.halfW ?? 1e9;
  if (Math.abs(x - rd.x0) > half + 1e-9)
    outside.push(`${what} at x=${x.toFixed(3)} is OUTSIDE road ${road} "${rd.name}" ` +
                 `[${(rd.x0-half).toFixed(2)}, ${(rd.x0+half).toFixed(2)}]${extra || ''}`);
};
for (const n of P.notes) check('notehead', n.road ?? 0, n.x, ` (t=${n.t.toFixed(3)})`);
for (const l of landings) check('ball landing', l.road, l.x, ` (t=${l.t.toFixed(3)} pitch=${l.pitch})`);
for (const d of P.drums) check('drum landing', d.road ?? 0, d.lane, ` (t=${d.t.toFixed(3)})`);

// ---- 5. BAND DISJOINTNESS: containment must mean identity -------------------
const overlaps = [];
for (let i = 0; i < roads.length; i++) for (let j = i + 1; j < roads.length; j++) {
  const a = roads[i], b = roads[j];
  const ah = a.halfW ?? 0, bh = b.halfW ?? 0;
  if (!isFinite(ah) || !isFinite(bh)) continue;
  if (Math.abs(a.x0 - b.x0) < ah + bh - 1e-9)
    overlaps.push(`roads "${a.name}" and "${b.name}" OVERLAP ` +
      `([${(a.x0-ah).toFixed(2)},${(a.x0+ah).toFixed(2)}] vs ` +
      `[${(b.x0-bh).toFixed(2)},${(b.x0+bh).toFixed(2)}]) — containment would prove nothing`);
}

console.log(`marks: ${roads.length} roads · ${P.notes.length} noteheads / ${landings.length} note landings · ` +
            `${side.length} side marks / ${P.drums.length} drum landings`);
for (const rd of roads)
  console.log(`  road ${rd.index} ${String(rd.name).padEnd(10)} ` +
    `band [${(rd.x0-(rd.halfW??0)).toFixed(2)}, ${(rd.x0+(rd.halfW??0)).toFixed(2)}]  ` +
    `${P.notes.filter(n => (n.road??0) === rd.index).length} heads  ` +
    `${P.drums.filter(d => (d.road??0) === rd.index).length} hits`);

const fail = [];
if (missingHead.length) fail.push(`${missingHead.length} note landing(s) with NO notehead ` +
  `(first: t=${missingHead[0].t.toFixed(3)} pitch=${missingHead[0].pitch} road=${missingHead[0].road})`);
if (missingMark.length) fail.push(`${missingMark.length} drum landing(s) with NO side mark ` +
  `(first: t=${missingMark[0].t.toFixed(3)} lane=${missingMark[0].lane})`);
if (orphanMark.length) fail.push(`${orphanMark.length} side mark(s) nothing lands on`);
if (orphanHead.length) fail.push(`${orphanHead.length} notehead(s) nothing lands on`);
if (outside.length) fail.push(`${outside.length} thing(s) drawn OFF THEIR OWN ROAD — first: ${outside[0]}`);
for (const o of overlaps) fail.push(o);

if (fail.length) { for (const f of fail) console.error(`  [ FAIL ] ${f}`); process.exit(1); }
console.log('  [ ok ] every landing has a mark, every mark has a landing, ' +
            'and everything sits inside its own road\'s band');
