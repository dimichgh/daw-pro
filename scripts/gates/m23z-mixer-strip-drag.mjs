// m23-z implementer gate — MIXER strip drag-to-reorder (47 legs), driven through
// the `debug.mixerStripDrag` staging seam on staging port 17695, PLUS the
// mandatory m23-h ARRANGE no-regression leg through `debug.trackHeaderDrag`
// (this item refactored the ONE landing registry the shipped arrange drag runs
// on, so unit-green is not seam-green).
//
// Usage:  env DAW_CONTROL_PORT=17695 nohup .build/debug/DAWApp &
//         node scripts/gates/m23z-mixer-strip-drag.mjs
//
// CALIBRATED 2026-07-26, three mutants, each caught by exactly the right legs:
//   1. naive visual-index pass-through  -> 32/47 (B2,B3,B5,B6,C2,C3,D1,D3,D4,E2
//      red; B5's observed order byte-identical to the `rejectedNaive` it prints)
//   2. one sampled gap (`gap(after: 0)`) -> 46/47, EXACTLY H1 red — and leg B3
//      on the A fixture STAYED GREEN, the measured proof that the
//      bus-between-channels fixture is blind to the gap bug and H is required
//   3. `gap(after: from)`, ignoring travel direction -> 45/47, D1 + I1 red
//      (H1 stays green — the two gap shapes are complementary, not redundant)
//
// THREE FIXTURE SHAPES, because no single one can see all three bugs:
//   A/B/C/D/E/G  [C0(chan), B1(bus), C2, C3] — a bus BETWEEN two channels; the
//                only shape on which the correct index reading and the naive
//                pass-through of the visual slot disagree.
//   H            [C0, B0(bus), B1(bus)] — the DIVIDER gap lands at index 0, so a
//                gap sampled from slot 0-1 (the arrange's trick) reads it.
//   I            [C0, C1, B0(bus)] — the divider gap sits directly BEHIND the
//                dragged strip while the drag goes the other way.
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function connect() {
  for (let i = 0; i < 25; i++) {
    try {
      return await new Promise((res, rej) => {
        const w = new WebSocket("ws://127.0.0.1:17695");
        w.addEventListener("open", () => res(w));
        w.addEventListener("error", () => rej(new Error("refused")));
      });
    } catch { await sleep(1000); }
  }
  throw new Error("no connect");
}
const ws = await connect();
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `mz${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
// The wire returns `error` as a bare string on this server, not {message}.
const msg = r => typeof r.error === "string" ? r.error : (r.error?.message ?? "");
const mix = async (p = {}) => (await cmd("debug.mixerStripDrag", p)).result ?? {};
const arr = async (p = {}) => (await cmd("debug.trackHeaderDrag", p)).result ?? {};

// ---------------------------------------------------------------- fixture
let r = await cmd("project.new", { discardChanges: true });
ck("A0 project.new", r.ok, JSON.stringify(r.error));
const ids = {};
for (const [name, kind] of [["C0", "audio"], ["B1", "bus"], ["C2", "audio"], ["C3", "audio"]]) {
  const t = await cmd("track.add", { name, kind });
  ids[name] = t.result?.id;
}
ck("A1 four tracks created, bus BETWEEN two channels",
   Object.keys(ids).length === 4 && Object.values(ids).every(Boolean), JSON.stringify(ids));

await cmd("ui.showMixer", { show: true });
await sleep(500);
let s = await mix();
ck("A2 console measured its own ladder (never computed)",
   s.stripCount === 4 && s.stripLefts.length === 4 && s.workspaceMode === "mix",
   JSON.stringify({ n: s.stripCount, lefts: s.stripLefts, mode: s.workspaceMode }));
ck("A3 visual order is channels-then-buses, NOT the array order",
   eq(s.visualNames, ["C0", "C2", "C3", "B1"]) && eq(s.names, ["C0", "B1", "C2", "C3"]),
   JSON.stringify({ visual: s.visualNames, array: s.names }));

const lefts = s.stripLefts, widths = s.stripWidths;
const gap = i => lefts[i + 1] - (lefts[i] + widths[i]);
const centre = i => lefts[i] + widths[i] / 2;
// THE GAP HAZARD, measured live: the divider gap is `10 + dividerWidth + 10`,
// and the divider's width is INTRINSIC (its "BUSES" caption). A computed ladder
// could not know it; a single sampled gap would report 10 for it.
ck("A4 the rack's gaps are NOT uniform — the divider gap is strictly larger",
   gap(2) > gap(0) + 5 && Math.abs(gap(0) - gap(1)) < 0.01,
   JSON.stringify([gap(0), gap(1), gap(2)]));
const plainGap = gap(0), W = widths[0];

// ------------------------------------------------- B: the index translation
const undo0 = s.undoDepth;
s = await mix({ act: "begin", trackId: ids.C0, x: centre(0) });
ck("B0 strip picked up, nothing committed", s.dragTrackId === ids.C0 && s.undoDepth === undo0,
   JSON.stringify({ drag: s.dragTrackId, depth: s.undoDepth }));
s = await mix({ act: "changed", x: centre(2) });
ck("B1 pointer over the LAST CHANNEL slot: visual 2 -> ARRAY 3 (the translation)",
   s.targetVisualIndex === 2 && s.targetArrayIndex === 3,
   JSON.stringify({ visual: s.targetVisualIndex, array: s.targetArrayIndex,
                    rejectedNaive: 2 }));
ck("B2 the line is DRAWN, at the target strip's far edge",
   s.moves === true && Math.abs(s.indicatorX - (lefts[2] + widths[2])) < 0.01,
   JSON.stringify({ moves: s.moves, x: s.indicatorX, expect: lefts[2] + widths[2] }));
ck("B3 the rack PARTS by the plain gap, never the divider gap",
   eq(s.partingOffsets.map(v => Math.round(v * 100) / 100),
      [0, -(W + plainGap), -(W + plainGap), 0].map(v => Math.round(v * 100) / 100)),
   JSON.stringify({ got: s.partingOffsets, plain: -(W + plainGap),
                    rejectedDivider: -(W + gap(2)) }));
ck("B4 NOTHING is committed until release",
   eq(s.names, ["C0", "B1", "C2", "C3"]) && s.undoDepth === undo0,
   JSON.stringify({ names: s.names, depth: s.undoDepth }));

s = await mix({ act: "end", x: centre(2) });
ck("B5 release commits the ARRAY index, not the visual one",
   eq(s.names, ["B1", "C2", "C3", "C0"]),
   JSON.stringify({ got: s.names, rejectedNaive: ["B1", "C2", "C0", "C3"] }));
ck("B6 the console now reads C2, C3, C0 | B1",
   eq(s.visualNames, ["C2", "C3", "C0", "B1"]), JSON.stringify(s.visualNames));
ck("B7 ONE undo step for the whole gesture, labelled",
   s.undoDepth === undo0 + 1 && s.undoLabel === "Move Track 'C0'",
   JSON.stringify({ depth: s.undoDepth, was: undo0, label: s.undoLabel }));
ck("B8 the strip is put down (no drag left in flight)", s.dragTrackId === null,
   JSON.stringify(s.dragTrackId));

const hist = (await cmd("edit.history")).result ?? {};
ck("B9 edit.history agrees the gesture is one step",
   (hist.undo?.length ?? 0) === undo0 + 1, JSON.stringify(hist.undo));

r = await cmd("edit.undo");
s = await mix();
ck("B10 one undo restores the order", eq(s.names, ["C0", "B1", "C2", "C3"]),
   JSON.stringify(s.names));

// ------------------------------------------- C: the visually-inert landing
s = await mix({ act: "begin", trackId: ids.C0, x: centre(0) });
s = await mix({ act: "changed", x: centre(3) });
ck("C1 the translation RAN on the bus slot (array 1), and 1 != from 0",
   s.targetVisualIndex === 3 && s.targetArrayIndex === 1 && s.fromIndex === 0,
   JSON.stringify({ v: s.targetVisualIndex, a: s.targetArrayIndex, from: s.fromIndex }));
ck("C2 …but the console would not change, so NO line and NO parting",
   s.moves === false && s.indicatorX === null && eq(s.partingOffsets, []),
   JSON.stringify({ moves: s.moves, x: s.indicatorX, part: s.partingOffsets }));
const depthBeforeInert = s.undoDepth;
s = await mix({ act: "end", x: centre(3) });
ck("C3 releasing on an inert landing commits nothing and spends no undo step",
   eq(s.names, ["C0", "B1", "C2", "C3"]) && s.undoDepth === depthBeforeInert,
   JSON.stringify({ names: s.names, depth: s.undoDepth, was: depthBeforeInert }));

// ------------------------------------------------------- D: the UP move
const undoUp = s.undoDepth;
s = await mix({ act: "begin", trackId: ids.C3, x: centre(2) });
s = await mix({ act: "changed", x: centre(0) });
ck("D1 an UP move targets visual 0 = array 0 and parts RIGHTWARD",
   s.targetVisualIndex === 0 && s.targetArrayIndex === 0 && s.moves === true &&
   eq(s.partingOffsets.map(v => Math.round(v * 100) / 100),
      [W + plainGap, W + plainGap, 0, 0].map(v => Math.round(v * 100) / 100)),
   JSON.stringify({ v: s.targetVisualIndex, a: s.targetArrayIndex, part: s.partingOffsets }));
ck("D2 the UP line sits at the target strip's NEAR edge",
   Math.abs(s.indicatorX - lefts[0]) < 0.01, JSON.stringify(s.indicatorX));
s = await mix({ act: "end", x: centre(0) });
ck("D3 the UP move lands", eq(s.names, ["C3", "C0", "B1", "C2"]), JSON.stringify(s.names));
ck("D4 the console follows", eq(s.visualNames, ["C3", "C0", "C2", "B1"]),
   JSON.stringify(s.visualNames));
ck("D5 one undo step for the up gesture too", s.undoDepth === undoUp + 1,
   JSON.stringify({ depth: s.undoDepth, was: undoUp }));

// ------------------------------- E: persistence (the array is the only carrier)
const proj = `/tmp/m23z-${Date.now()}`;
r = await cmd("project.save", { path: proj });
ck("E0 saved", r.ok, JSON.stringify(r.error));
r = await cmd("project.open", { path: r.result?.path ?? proj });
ck("E1 reopened", r.ok, JSON.stringify(r.error));
let ov = (await cmd("project.overview")).result ?? {};
ck("E2 the mixer-made order survived the round trip",
   eq((ov.tracks ?? []).map(t => t.name), ["C3", "C0", "B1", "C2"]),
   JSON.stringify((ov.tracks ?? []).map(t => t.name)));

// --------------------------------------------------- F: read-only + refusals
await cmd("ui.showMixer", { show: true });
await sleep(400);
const before = await mix();
const after = await mix();
ck("F1 a bare read stages nothing", eq(before.names, after.names) &&
   before.undoDepth === after.undoDepth && after.dragTrackId === null,
   JSON.stringify({ b: before.names, a: after.names }));
r = await cmd("debug.mixerStripDrag", { act: "wiggle", x: 10 });
ck("F2 an unknown act is refused, naming the valid ones",
   !r.ok && /begin/.test(msg(r)), JSON.stringify(r.error));
r = await cmd("debug.mixerStripDrag", { act: "begin", trackId: ids.C0 });
ck("F3 a staged act without an x is refused", !r.ok && /x/.test(msg(r)),
   JSON.stringify(r.error));
r = await cmd("debug.mixerStripDrag", { act: "changed", trackId: ids.C0, x: 10 });
ck("F4 only 'begin' takes a trackId", !r.ok && /begin/.test(msg(r)),
   JSON.stringify(r.error));
r = await cmd("debug.mixerStripDrag", { x: 10 });
ck("F5 an x with no act is refused", !r.ok, JSON.stringify(r.error));
r = await cmd("debug.mixerStripDrag", { act: "begin", trackId: "not-a-uuid", x: 10 });
ck("F6 a malformed trackId is refused", !r.ok, JSON.stringify(r.error));

// ------------------------------------- G: ARRANGE NO-REGRESSION (m23-h live)
// The mixer work refactored `TrackReorderDrag` — the ONE registry the shipped
// arrange drag runs on. Unit-green is not seam-green.
// Its own FRESH fixture, deliberately: state-coupling this leg to the mixer
// legs above would make it go red for the mixer's reasons and stop being a
// no-regression instrument.
await cmd("project.new", { discardChanges: true });
for (const [name, kind] of [["C0", "audio"], ["B1", "bus"], ["C2", "audio"], ["C3", "audio"]]) {
  ids[name] = (await cmd("track.add", { name, kind })).result?.id;
}
await cmd("ui.showMixer", { show: false });
await sleep(500);
let a = await arr();
ck("G0 the arrange ladder still measures", a.rowCount === 4 && a.rowTops.length === 4,
   JSON.stringify({ n: a.rowCount, tops: a.rowTops }));
const tops = a.rowTops, hs = a.rowHeights;
const undoA = a.undoDepth;
// DOWN: C0 (row 0) → row 2. The arrange renders the array RAW, so row 2 IS
// array index 2 — no translation, which is exactly the contrast with the mixer.
a = await arr({ act: "begin", trackId: ids.C0, y: tops[0] + hs[0] / 2 });
ck("G1 the arrange still picks a row up", a.dragTrackId === ids.C0, JSON.stringify(a.dragTrackId));
a = await arr({ act: "changed", y: tops[2] + hs[2] / 2 });
ck("G2 the arrange still resolves a landing + draws its line at the FAR edge",
   a.targetIndex === 2 && a.moves === true &&
   Math.abs(a.indicatorY - (tops[2] + hs[2])) < 0.01,
   JSON.stringify({ i: a.targetIndex, y: a.indicatorY, expect: tops[2] + hs[2] }));
ck("G3 the arrange still commits nothing until release",
   eq(a.names, ["C0", "B1", "C2", "C3"]) && a.undoDepth === undoA, JSON.stringify(a.names));
a = await arr({ act: "end", y: tops[2] + hs[2] / 2 });
ck("G4 the arrange DOWN drag still lands at the FINAL index, one undo step",
   eq(a.names, ["B1", "C2", "C0", "C3"]) && a.undoDepth === undoA + 1,
   JSON.stringify({ names: a.names, depth: a.undoDepth }));
// UP: C3 (now row 3) → row 1.
a = await arr({ act: "begin", trackId: ids.C3, y: tops[3] + hs[3] / 2 });
a = await arr({ act: "changed", y: tops[1] + hs[1] / 2 });
ck("G5 the arrange UP move still resolves, line at the NEAR edge",
   a.targetIndex === 1 && a.moves === true && Math.abs(a.indicatorY - tops[1]) < 0.01,
   JSON.stringify({ i: a.targetIndex, y: a.indicatorY }));
a = await arr({ act: "end", y: tops[1] + hs[1] / 2 });
ck("G6 the arrange UP move still lands", eq(a.names, ["B1", "C3", "C2", "C0"]),
   JSON.stringify(a.names));
a = await arr({ act: "begin", trackId: ids.C0, y: tops[3] + hs[3] / 2 });
ck("G7 a no-op arrange landing still draws NO line",
   a.moves === false && a.indicatorY === null,
   JSON.stringify({ moves: a.moves, y: a.indicatorY, names: a.names }));
await arr({ act: "end", y: tops[3] + hs[3] / 2 });

// ------------- H/I: the GAP shapes (the A fixture is blind to a sampled gap)
// On [C0,B1,C2,C3] the divider gap sits at index 2, so gap(0) is already the
// plain 10 and a sampled-gap implementation passes leg B3 by luck. These two
// shapes put the divider gap where a wrong reading has to show.
async function rack(spec) {
  await cmd("project.new", { discardChanges: true });
  const map = {};
  for (const [name, kind] of spec) map[name] = (await cmd("track.add", { name, kind })).result?.id;
  await cmd("ui.showMixer", { show: true });
  await sleep(500);
  return [map, await mix()];
}

// H — ONE channel, TWO buses: the DIVIDER gap is gap(0), the vacated gap is gap(1).
let [hIds, h] = await rack([["C0", "audio"], ["B0", "bus"], ["B1", "bus"]]);
const hGap = i => h.stripLefts[i + 1] - (h.stripLefts[i] + h.stripWidths[i]);
const hCentre = i => h.stripLefts[i] + h.stripWidths[i] / 2;
ck("H0 the divider gap is now at index 0 — sampling gap(0) would read it",
   hGap(0) > hGap(1) + 5 && eq(h.visualNames, ["C0", "B0", "B1"]),
   JSON.stringify({ gaps: [hGap(0), hGap(1)], visual: h.visualNames }));
await mix({ act: "begin", trackId: hIds.B0, x: hCentre(1) });
h = await mix({ act: "changed", x: hCentre(2) });
ck("H1 the two buses swap, parting by the PLAIN gap — not the sampled divider gap",
   h.moves === true &&
   eq(h.partingOffsets.map(v => Math.round(v * 100) / 100),
      [0, 0, Math.round(-(h.stripWidths[0] + hGap(1)) * 100) / 100]),
   JSON.stringify({ got: h.partingOffsets, plain: -(h.stripWidths[0] + hGap(1)),
                    rejectedSampled: -(h.stripWidths[0] + hGap(0)) }));
h = await mix({ act: "end", x: hCentre(2) });
ck("H2 …and it lands", eq(h.visualNames, ["C0", "B1", "B0"]), JSON.stringify(h.visualNames));

// I — TWO channels, ONE bus: the divider gap sits AFTER the dragged strip while
// the drag goes the other way, so `gap(after: from)` would inflate the parting.
let [iIds, iS] = await rack([["C0", "audio"], ["C1", "audio"], ["B0", "bus"]]);
const iGap = k => iS.stripLefts[k + 1] - (iS.stripLefts[k] + iS.stripWidths[k]);
const iCentre = k => iS.stripLefts[k] + iS.stripWidths[k] / 2;
ck("I0 the divider gap is at index 1, directly behind the strip we will drag",
   iGap(1) > iGap(0) + 5, JSON.stringify([iGap(0), iGap(1)]));
await mix({ act: "begin", trackId: iIds.C1, x: iCentre(1) });
iS = await mix({ act: "changed", x: iCentre(0) });
ck("I1 departing LEFT closes the LEFT gap — `gap(after: from)` would use the divider",
   iS.moves === true &&
   eq(iS.partingOffsets.map(v => Math.round(v * 100) / 100),
      [Math.round((iS.stripWidths[0] + iGap(0)) * 100) / 100, 0, 0]),
   JSON.stringify({ got: iS.partingOffsets, plain: iS.stripWidths[0] + iGap(0),
                    rejectedAfterFrom: iS.stripWidths[0] + iGap(1) }));
iS = await mix({ act: "end", x: iCentre(0) });
ck("I2 …and it lands", eq(iS.names, ["C1", "C0", "B0"]), JSON.stringify(iS.names));

console.log(`\nm23-z gate: ${pass} pass / ${fail} fail`);
ws.close();
process.exit(fail === 0 ? 0 : 1);
