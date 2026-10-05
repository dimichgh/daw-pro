// m34-a-2 + m34-a-3 GATE — CAN YOU SEE THE TAKE, AND DOES THE VIEW COME TO IT?
//
// Reported: *"when I record playing using keys on instrument track it would be
// good to automatically create and auto extend [the region] as user plays and it
// should also autoposition on the area where the notes are placed and progress
// as user keeps playing."*
//
// m34-a-1 shipped the horizontal half (the view follows the playhead during a
// take). These two sub-items are what was left:
//
//   a-2  THE GROWING TAKE REGION — the clip was materialised ONLY AT STOP
//        (`MIDICaptureSession.finish(atBeat:)`), so the timeline was genuinely
//        blank while you played. A PROVISIONAL region now appears and grows.
//   a-3  VERTICAL FOLLOW — recording on track 12 of 14 while staring at tracks
//        1–6 is as useless as not following time at all.
//
// ── THE ARMS ────────────────────────────────────────────────────────────────
//  A1  a rolling take with NO notes draws NOTHING          ⛔ the ghost control
//  A2  one note → a region appears, on the armed lane      ⭐ the sub-item
//  A3  the region GROWS as the take runs                   ⭐ "auto extend"
//  A4  it is NOT a clip while it is provisional            ⛔ the data-loss shape
//  A5  at stop the region is GONE and a real clip landed, at the same beats
//  A6  a take that captured nothing leaves NO clip and NO ghost
//  V1  the armed row is OUT of view → the view scrolls DOWN to it  ⭐ a-3
//  V2  the armed row is ALREADY VISIBLE → zero vertical scrolls    ⛔ never re-centre
//  V3  plain PLAYBACK with the row out of view → zero vertical scrolls
//  V4  a manual vertical scroll mid-take SUSPENDS vertical follow
//
// ⭐⭐ **EVERY NEGATIVE HAS A POSITIVE CONTROL ON THE SAME FIXTURE.** A1's
// `region === null` means nothing unless A2 can produce a region from the same
// take; V2's `scrolls === 0` means nothing unless V1 can produce a non-zero from
// the same session and geometry. The difference between each pair is exactly one
// fact — a note played, or which row is armed — and nothing else.
//
// ⚠️ **GEOMETRY IS ASSERTED BEFORE ANY VERTICAL ZERO IS BELIEVED** (the m34-a-1
// rule): a content height that does not exceed the viewport makes every reveal
// return nil forever, and every `scrolls === 0` here would pass for a reason
// that has nothing to do with follow.
//
// ⚠️ COUNT-IN IS PINNED TO 0, deliberately (the m23-cy interaction): the project
// default is one bar, which freezes the playhead for 2.0 s and drops every note
// played into it as pre-anchor. Correct behaviour — a count-in genuinely has no
// clip coming yet — but it would eat this gate's sample window.
//
// ⚠️ Sticky UserDefaults slots (`followPlayhead`, arrange `ppb`, row step) are
// READ FIRST and RESTORED at the end — the m23-ei / m23-du(b) law.
//
// Staging: DAW_CONTROL_PORT=17695, pidfile-exact teardown. NEVER 17600.
import { sleep, buildOrAbort, startStaging, stopStaging, connect, verdict } from "./_staging.mjs";

const GATE = "m34a23-take-region-and-vfollow";
buildOrAbort({ label: "building staging binary (m34-a-2/a-3)…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `tr${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 30000);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t);
      ws.removeEventListener("message", h);
      res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
const req = async (c, p) => {
  const m = await cmd(c, p);
  if (!m.ok) console.log(`  ⚠️ ${c} -> ${JSON.stringify(m.error)}`);
  return m.result ?? {};
};

let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + JSON.stringify(extra) : "")); }
};

// ⚠️ Priors BEFORE the fixture writes them.
const priorLayout = await req("debug.panelLayout", {});
const priorZoom = await req("debug.arrangeZoom", {});
console.log(`prior sticky slots: followPlayhead=${priorLayout.followPlayhead} arrangePPB=${priorZoom.ppb} rowStep=${priorZoom.rowStep}`);

const TRACKS = 20;     // deep enough that the bottom rows cannot fit the viewport
const PPB = 40;
const ARMED_DEEP = 17; // a row far below the fold
const ARMED_TOP = 0;   // a row that is always visible

/** A deep session; arms exactly ONE instrument track and returns every id. */
async function buildFixture(armIndex) {
  await req("project.new", { discardChanges: true });
  // A SHORT window on purpose: the vertical arms need content > viewport, and
  // asserting that is cheaper than hoping a tall window still overflows.
  await req("debug.windowFrame", { width: 1200, height: 620 });
  const ids = [];
  for (let i = 0; i < TRACKS; i++) {
    const tr = await req("track.add", { name: `T${i}`, kind: "instrument" });
    ids.push(tr.id ?? tr.track?.id);
  }
  await req("debug.arrangeZoom", { ppb: PPB, rowStep: "small" });
  await req("debug.panelLayout", { followPlayhead: false });   // the take must engage it
  await req("track.setArm", { trackId: ids[armIndex], armed: true });
  await req("transport.setMetronome", { enabled: false, countInBars: 0 });  // see header
  // Park the vertical scroll at the TOP, so "out of view" is a fact about the
  // fixture rather than an assumption about where a fresh project starts.
  await req("debug.arrangeScroll", { index: 0, bottom: false });
  await sleep(500);
  return ids;
}

/** Holds `pitch` on `trackId` for `ms`, then releases. Echoes the capture flag. */
async function playNote(trackId, pitch, ms) {
  const on = await req("note.play", { trackId, pitches: [pitch], velocity: 100 });
  await sleep(ms);
  await req("note.play", { trackId, pitches: [], velocity: 0 });
  return on;
}

// ════ a-2: THE GROWING TAKE REGION ═════════════════════════════════════════
console.log("\n=== FIXTURE ===");
let ids = await buildFixture(ARMED_DEEP);
const armedId = ids[ARMED_DEEP];

console.log("\n=== A1: a rolling take with NO notes draws NOTHING (the ghost control) ===");
await req("transport.seek", { beats: 0 });
await req("transport.record", {});
await sleep(1500);
const silent = await req("debug.takeRegion", {});
console.log(`  [measured] silent take: isRecording=${silent.isRecording} region=${JSON.stringify(silent.region)} ` +
  `pendingStart=${silent.pending?.startBeat} loop=${silent.pending?.isLoopTake}`);
// POSITIVE CONTROLS for the null: a take really is rolling, and it really has a
// destination. Without these, `region === null` is also what a broken fixture,
// a refused record and a crashed app all look like.
ck("A1: the take IS rolling (positive control for the null below)", silent.isRecording === true, silent.isRecording);
ck("A1: the take HAS an instrument destination (positive control)",
   (silent.pending?.instrumentTrackIds ?? []).includes(armedId), silent.pending);
ck("⛔ A1: a take that has captured NOTHING draws NO region — no ghost is promised",
   silent.region === null, silent.region);

console.log("\n=== A2/A3: a note appears as a region, and the region GROWS ===");
const played = await playNote(armedId, 62, 400);
console.log(`  [measured] note.play -> audible=${played.audible} captured=${played.capturedEdges} recording=${played.recording}`);
ck("A2: the note actually reached the rolling take (positive control for the region)",
   played.recording === true, played);
await sleep(400);
const first = await req("debug.takeRegion", {});
await sleep(2200);
const later = await req("debug.takeRegion", {});
console.log(`  [measured] region first=${JSON.stringify(first.region)}\n  [measured] region later=${JSON.stringify(later.region)}`);
ck("⭐⭐ A2: one note makes a PROVISIONAL region appear", first.region !== null, first.region);
ck("A2: it is drawn on the ARMED lane, and only there",
   JSON.stringify(first.region?.trackIds) === JSON.stringify([armedId]), first.region?.trackIds);
ck("A2: it starts where the clip will land (the take's record position)",
   first.region?.startBeat === 0, first.region?.startBeat);
ck("A2: it reports the notes captured so far", (first.region?.noteCount ?? 0) >= 1, first.region?.noteCount);
ck("⭐⭐ A3: the region GROWS as the take runs — 'auto extend as user plays'",
   (later.region?.lengthBeats ?? 0) > (first.region?.lengthBeats ?? 0),
   { first: first.region?.lengthBeats, later: later.region?.lengthBeats });
ck("A3: and it never shrinks below the take's own start",
   (later.region?.startBeat ?? -1) === (first.region?.startBeat ?? -2),
   { first: first.region?.startBeat, later: later.region?.startBeat });

console.log("\n=== A4: while provisional it is NOT a clip (the data-loss shape) ===");
const midTake = await req("project.snapshot", {});
const midClips = (midTake.tracks ?? []).flatMap((t) => t.clips ?? []);
console.log(`  [measured] clips on the timeline mid-take: ${midClips.length}`);
ck("⛔⛔ A4: the provisional region is NOT in the project — nothing can select, drag or undo it",
   midClips.length === 0, midClips.map((c) => c.id));

// ⭐ A UI PHASE IS NOT DONE UNTIL SOMEONE HAS LOOKED AT IT. Captured mid-take,
// with the region on screen, so a human can see whether it reads as provisional.
const shot = await req("debug.captureUI", { path: "/tmp/m34a2-take-region.png", scale: 2 });
console.log(`  [captured] ${shot.path ?? shot.file ?? JSON.stringify(shot)}`);

const lastRegion = await req("debug.takeRegion", {});
await req("transport.stop", {});
await sleep(1200);

console.log("\n=== A5: at stop the region is GONE and a real clip took its place ===");
const after = await req("debug.takeRegion", {});
const snap = await req("project.snapshot", {});
const landed = (snap.tracks ?? []).flatMap((t) => (t.clips ?? []).map((c) => ({ track: t.id, ...c })));
console.log(`  [measured] after stop: region=${JSON.stringify(after.region)} clips=${landed.length} ` +
  `${landed.map((c) => `${c.startBeat}+${c.lengthBeats}`).join(",")}`);
ck("⭐ A5: the provisional region is gone the moment the take is", after.region === null, after.region);
ck("A5: a real clip landed on the armed track", landed.length === 1 && landed[0].track === armedId, landed);
ck("A5: it starts where the region did", landed[0]?.startBeat === lastRegion.region?.startBeat,
   { clip: landed[0]?.startBeat, region: lastRegion.region?.startBeat });
// The swap is not required to be pixel-identical: the stop happens strictly
// after the last poll, so the clip may be one whole beat longer. It must never
// be SHORTER than what was drawn, and never more than a beat longer.
const grew = (landed[0]?.lengthBeats ?? 0) - (lastRegion.region?.lengthBeats ?? 0);
ck("⭐ A5: the clip matches the last region drawn (0…1 beat longer — the stop is after the last poll)",
   grew >= 0 && grew <= 1, { clip: landed[0]?.lengthBeats, lastRegion: lastRegion.region?.lengthBeats, delta: grew });

console.log("\n=== A6: a take that captures NOTHING leaves no clip and no ghost ===");
await req("transport.seek", { beats: 0 });
const clipsBefore = ((await req("project.snapshot", {})).tracks ?? []).flatMap((t) => t.clips ?? []).length;
await req("transport.record", {});
await sleep(2000);
const duringEmpty = await req("debug.takeRegion", {});
await req("transport.stop", {});
await sleep(1200);
const afterEmpty = await req("debug.takeRegion", {});
const clipsAfter = ((await req("project.snapshot", {})).tracks ?? []).flatMap((t) => t.clips ?? []).length;
console.log(`  [measured] empty take: duringRegion=${JSON.stringify(duringEmpty.region)} clips ${clipsBefore} -> ${clipsAfter}`);
ck("A6: no region during a silent take", duringEmpty.region === null, duringEmpty.region);
ck("A6: no region after it", afterEmpty.region === null, afterEmpty.region);
ck("⛔ A6: and NO clip was created — the region never promised one",
   clipsAfter === clipsBefore, { before: clipsBefore, after: clipsAfter });

// ════ a-3: VERTICAL FOLLOW TO THE ARMED ROW ════════════════════════════════
console.log("\n=== V-GEOMETRY: without this every vertical zero below is meaningless ===");
ids = await buildFixture(ARMED_DEEP);
const deepId = ids[ARMED_DEEP];
const vgeo = await req("debug.followPlayhead", {});
console.log(`  [measured] vertical: viewport=${vgeo.arrangeVertical?.viewportHeight} content=${vgeo.arrangeVertical?.contentHeight} ` +
  `offset=${vgeo.arrangeVertical?.offset} rowTop=${vgeo.arrangeVertical?.rowTop} rowHeight=${vgeo.arrangeVertical?.rowHeight}`);
ck("⭐ V-geo: the arrange has somewhere to scroll VERTICALLY (content > viewport)",
   (vgeo.arrangeVertical?.contentHeight ?? 0) > (vgeo.arrangeVertical?.viewportHeight ?? 0) + 40,
   vgeo.arrangeVertical);
ck("V-geo: the view starts scrolled to the TOP", (vgeo.arrangeVertical?.offset ?? 99) < 1, vgeo.arrangeVertical?.offset);

console.log("\n=== V3: plain PLAYBACK does NOT scroll to the armed row ===");
await req("transport.seek", { beats: 0 });
await req("debug.followPlayhead", { rearm: true, resetCounters: true });
await req("transport.play", {});
await sleep(2500);
const vPlay = await req("debug.followPlayhead", {});
await req("transport.stop", {});
await sleep(600);
console.log(`  [measured] playback: vScrolls=${vPlay.arrangeVertical?.scrolls} vOffset=${vPlay.arrangeVertical?.offset} ` +
  `vEnabled=${vPlay.arrangeVertical?.enabledEffective}`);
ck("V3: ordinary playback never scrolls vertically — there is nothing to follow but a take",
   vPlay.arrangeVertical?.scrolls === 0, vPlay.arrangeVertical);
ck("V3: and the vertical enable is off during playback",
   vPlay.arrangeVertical?.enabledEffective === false, vPlay.arrangeVertical?.enabledEffective);

console.log("\n=== V1: a TAKE on a row that is OUT of view scrolls DOWN to it ===");
await req("transport.seek", { beats: 0 });
await req("debug.arrangeScroll", { index: 0, bottom: false });
await sleep(400);
await req("debug.followPlayhead", { rearm: true, resetCounters: true });
const vBefore = await req("debug.followPlayhead", {});
await req("transport.record", {});
await sleep(1200);
const vDuring = await req("debug.followPlayhead", {});
await req("transport.stop", {});
await sleep(800);
console.log(`  [measured] take/deep row: offset ${vBefore.arrangeVertical?.offset} -> ${vDuring.arrangeVertical?.offset}, ` +
  `vScrolls=${vDuring.arrangeVertical?.scrolls} anchorsBottom=${vDuring.arrangeVertical?.anchorsBottom} ` +
  `rowTop=${vDuring.arrangeVertical?.rowTop}`);
ck("⭐⭐ V1: a take on an out-of-view row issues a vertical reveal",
   (vDuring.arrangeVertical?.scrolls ?? 0) > 0, vDuring.arrangeVertical);
ck("⭐ V1: and the view actually MOVED — a scroll count without an offset change would be a lie",
   (vDuring.arrangeVertical?.offset ?? 0) > (vBefore.arrangeVertical?.offset ?? 0) + 10,
   { before: vBefore.arrangeVertical?.offset, after: vDuring.arrangeVertical?.offset });
ck("V1: the armed row is now inside the viewport",
   (vDuring.arrangeVertical?.rowTop ?? 0) >= (vDuring.arrangeVertical?.offset ?? 0) - 1 &&
   (vDuring.arrangeVertical?.rowTop ?? 0) + (vDuring.arrangeVertical?.rowHeight ?? 0)
     <= (vDuring.arrangeVertical?.offset ?? 0) + (vDuring.arrangeVertical?.viewportHeight ?? 0) + 1,
   vDuring.arrangeVertical);
ck("V1: the reveal anchored against the BOTTOM edge (the row was below)",
   vDuring.arrangeVertical?.anchorsBottom === true, vDuring.arrangeVertical?.anchorsBottom);

console.log("\n=== V2: a take on a row that is ALREADY VISIBLE never re-centres it ===");
ids = await buildFixture(ARMED_TOP);
await req("transport.seek", { beats: 0 });
await req("debug.followPlayhead", { rearm: true, resetCounters: true });
const topBefore = await req("debug.followPlayhead", {});
await req("transport.record", {});
await sleep(1800);
const topDuring = await req("debug.followPlayhead", {});
await req("transport.stop", {});
await sleep(800);
console.log(`  [measured] take/visible row: offset ${topBefore.arrangeVertical?.offset} -> ${topDuring.arrangeVertical?.offset}, ` +
  `vScrolls=${topDuring.arrangeVertical?.scrolls} hScrolls=${topDuring.arrange?.scrolls}`);
ck("V2: the vertical enable WAS on during this take (positive control for the zero)",
   topDuring.arrangeVertical?.enabledEffective === true, topDuring.arrangeVertical?.enabledEffective);
ck("⛔⛔ V2: an ALREADY VISIBLE row is never scrolled to — the asymmetry with horizontal follow",
   topDuring.arrangeVertical?.scrolls === 0, topDuring.arrangeVertical);
ck("V2: and the view did not move vertically",
   Math.abs((topDuring.arrangeVertical?.offset ?? 0) - (topBefore.arrangeVertical?.offset ?? 0)) < 1,
   { before: topBefore.arrangeVertical?.offset, after: topDuring.arrangeVertical?.offset });

console.log("\n=== V4: a manual vertical scroll mid-take suspends vertical follow ===");
ids = await buildFixture(ARMED_DEEP);
await req("transport.seek", { beats: 0 });
await req("debug.arrangeScroll", { index: 0, bottom: false });
await sleep(400);
await req("debug.followPlayhead", { rearm: true, resetCounters: true });
await req("transport.record", {});
await sleep(1200);
const beforeDrag = await req("debug.followPlayhead", {});
// The same seam a real vertical drag reaches the detector on: an offset follow
// never asked for.
await req("debug.followPlayhead", { simulateUserScroll: 7, surface: "arrangeVertical" });
await sleep(1200);
const afterDrag = await req("debug.followPlayhead", {});
await req("transport.stop", {});
await sleep(800);
console.log(`  [measured] before drag vScrolls=${beforeDrag.arrangeVertical?.scrolls} suspended=${beforeDrag.arrangeVertical?.suspended}; ` +
  `after vScrolls=${afterDrag.arrangeVertical?.scrolls} suspended=${afterDrag.arrangeVertical?.suspended}`);
ck("V4a: vertical follow WAS driving this take before the drag (positive control for V4b)",
   (beforeDrag.arrangeVertical?.scrolls ?? 0) > 0, beforeDrag.arrangeVertical);
ck("⭐ V4b: a manual vertical scroll during the take SUSPENDS it — the shipped policy, not a second one",
   afterDrag.arrangeVertical?.suspended === true, afterDrag.arrangeVertical);
// The stand-down must not outlive the take.
await req("transport.seek", { beats: 0 });
await req("transport.record", {});
await sleep(600);
const rearmed = await req("debug.followPlayhead", {});
await req("transport.stop", {});
await sleep(800);
ck("⭐ V4c: the NEXT take re-arms the vertical axis — a stand-down never outlives its take",
   rearmed.arrangeVertical?.suspended === false, rearmed.arrangeVertical);

// ── RESTORE the sticky slots ────────────────────────────────────────────────
await req("debug.panelLayout", { followPlayhead: priorLayout.followPlayhead });
await req("debug.arrangeZoom", { ppb: priorZoom.ppb, rowStep: priorZoom.rowStep });
const restored = await req("debug.panelLayout", {});
const restoredZoom = await req("debug.arrangeZoom", {});
console.log(`\nrestored sticky slots: followPlayhead=${restored.followPlayhead} arrangePPB=${restoredZoom.ppb} rowStep=${restoredZoom.rowStep}`);
ck("sticky followPlayhead restored to the value found on arrival",
   restored.followPlayhead === priorLayout.followPlayhead,
   { prior: priorLayout.followPlayhead, now: restored.followPlayhead });
ck("sticky arrange ppb restored to the value found on arrival",
   restoredZoom.ppb === priorZoom.ppb, { prior: priorZoom.ppb, now: restoredZoom.ppb });

stopStaging(GATE);
verdict({ ran: pass + fail, failed: fail });
