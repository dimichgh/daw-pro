// PREMISE PROBE for m23-cy (count-in default) + m23-cu-1 (follow during a take).
//
// ⚠️ THIS IS A PROBE, NOT A GATE. It PRINTS what the shipped tree does today,
// BEFORE either change lands. Its whole job is to turn two source-traced
// hypotheses into measurements — "a complete chain on paper is still a
// hypothesis" — so it deliberately asserts nothing and exits 0 regardless.
// Underscore-prefixed, so `m23fa3-verdict-enforcement.mjs` correctly skips it.
//
// PREMISE 1 (m23-cy) — count-in semantics, three arms:
//   A. countInBars 0, note struck with ZERO delay after `transport.record`
//      → expected DROPPED. This is the user's reported symptom, reproduced.
//   B. countInBars 1, note struck AFTER the count-in elapses
//      → expected RECORDED, at a SMALL startBeat (the take excludes the count-in).
//   C. countInBars 1, note struck DURING the count-in
//      → expected DROPPED. `MIDICaptureSession.swift:12` says the anchor is
//      "already count-in-delayed, and note-ons with beat < the anchor beat are
//      dropped". If C lands, that source comment is wrong and the whole item's
//      framing changes.
//   ⭐ Arm B is arm A's and arm C's POSITIVE CONTROL: without a note that DOES
//   land, an empty read is the weakest evidence there is.
//
// PREMISE 2 (m23-cu-1) — does the arrange follow the playhead during a TAKE?
//   D. followPlayhead ON  + a real take → expected arrange.scrolls > 0
//   E. followPlayhead OFF + a real take → expected arrange.scrolls == 0
//   E is D's negative control (and D is E's positive control).
//
// Staging: DAW_CONTROL_PORT=17695, pidfile-exact teardown. NEVER 17600.
import { sleep, buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";

const GATE = "_m23cy-cu1-premise-probe";
buildOrAbort({ label: "building staging binary (m23-cy/cu-1 premise probe)…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `pp${++n}`;
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

async function notesOn(trackId) {
  const snap = await req("project.snapshot");
  const out = [];
  for (const track of snap.tracks ?? []) {
    if (track.id !== trackId) continue;
    for (const clip of track.clips ?? []) {
      const got = await req("clip.getNotes", { clipId: clip.id });
      for (const note of got.notes ?? []) out.push({ clip: clip.name, ...note });
    }
  }
  return out;
}

// ── PREMISE 1: count-in ─────────────────────────────────────────────────────
// One arm: fresh project, armed instrument track, the given count-in, a note
// struck `strikeAfterMs` after `transport.record`, held 700 ms, take stopped
// `stopAfterMs` after record. Returns the notes that survived.
async function countInArm({ label, countInBars, strikeAfterMs, stopAfterMs, pitch }) {
  console.log(`\n--- ARM ${label}: countInBars=${countInBars}, strike at +${strikeAfterMs} ms, stop at +${stopAfterMs} ms ---`);
  await req("project.new", { discardChanges: true });
  const tr = await req("track.add", { name: `probe ${label}`, kind: "instrument" });
  const trackId = tr.id ?? tr.track?.id;
  await req("track.setArm", { trackId, armed: true });
  const metro = await req("transport.setMetronome", { enabled: false, countInBars });
  console.log(`  setMetronome echo: countInBars=${metro.countInBars}`);

  const t0 = Date.now();
  await req("transport.record", {});
  const recAt = Date.now() - t0;
  if (strikeAfterMs > 0) await sleep(strikeAfterMs);
  const on = await req("note.play", { trackId, pitches: [pitch] });
  const strikeAt = Date.now() - t0;
  await sleep(700);
  await req("note.play", { trackId, pitches: [] });
  const releaseAt = Date.now() - t0;
  const remaining = stopAfterMs - (Date.now() - t0);
  if (remaining > 0) await sleep(remaining);
  await req("transport.stop", {});
  console.log(`  timing: record returned +${recAt} ms, note-on +${strikeAt} ms, note-off +${releaseAt} ms`);
  console.log(`  note.play echo: recording=${on.recording} capturedEdges=${on.capturedEdges}`);

  let notes = [];
  for (let i = 0; i < 16; i++) {
    await sleep(250);
    notes = await notesOn(trackId);
    if (notes.length > 0) break;
  }
  console.log(`  [MEASURED] notes that survived: ${JSON.stringify(notes)}`);
  return notes;
}

console.log("\n=================  PREMISE 1 — COUNT-IN SEMANTICS  =================");

// B FIRST: it is the positive control for A and C. If nothing can land, an
// empty A/C proves nothing at all.
const armB = await countInArm({
  label: "B (countInBars 1, strike AFTER the count-in — the FIX)",
  countInBars: 1, strikeAfterMs: 2300, stopAfterMs: 4200, pitch: 62,
});
const armA = await countInArm({
  label: "A (countInBars 0, strike IMMEDIATELY — the USER'S SYMPTOM)",
  countInBars: 0, strikeAfterMs: 0, stopAfterMs: 2500, pitch: 60,
});
const armC = await countInArm({
  label: "C (countInBars 1, strike DURING the count-in)",
  countInBars: 1, strikeAfterMs: 400, stopAfterMs: 4200, pitch: 64,
});

console.log("\n[SUMMARY premise 1]");
console.log(`  B (after count-in): ${armB.length} note(s)` +
  (armB.length ? ` startBeat=${armB[0].startBeat} len=${armB[0].lengthBeats}` : ""));
console.log(`  A (t=0, no count-in): ${armA.length} note(s)` +
  (armA.length ? ` startBeat=${armA[0].startBeat}` : ""));
console.log(`  C (during count-in): ${armC.length} note(s)` +
  (armC.length ? ` startBeat=${armC[0].startBeat}` : ""));

// ── PREMISE 2: follow during a take ─────────────────────────────────────────
console.log("\n=================  PREMISE 2 — FOLLOW DURING A TAKE  =================");

// ⚠️ Read the sticky slots BEFORE writing them (m23-ei / m23-du(b)): a restore
// to a value this probe itself set is not a restore.
const priorLayout = await req("debug.panelLayout", {});
const priorZoom = await req("debug.arrangeZoom", {});
console.log(`prior sticky slots: followPlayhead=${priorLayout.followPlayhead} arrangePPB=${priorZoom.ppb}`);

const PPB = 100, CLIP_BEATS = 128;

async function followArm({ label, follow }) {
  console.log(`\n--- ARM ${label}: followPlayhead=${follow} ---`);
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const tr = await req("track.add", { name: `follow ${label}`, kind: "instrument" });
  const trackId = tr.id ?? tr.track?.id;
  const notes = [];
  for (let b = 0; b < CLIP_BEATS; b += 4) {
    notes.push({ pitch: 60, startBeat: b, lengthBeats: 0.9, velocity: 100 });
  }
  await req("clip.addMIDI", { trackId, atBeat: 0, lengthBeats: CLIP_BEATS, notes });
  await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.panelLayout", { followPlayhead: follow });
  await req("track.setArm", { trackId, armed: true });
  // countInBars 0 so the take rolls immediately — this arm is about follow, and
  // a 2 s frozen playhead would just eat the sample window.
  await req("transport.setMetronome", { enabled: false, countInBars: 0 });

  const geo0 = await req("debug.followPlayhead", { rearm: true, resetCounters: true });
  console.log(`  geometry: viewport=${geo0.arrange.viewportWidth} content=${geo0.arrange.contentWidth} offset=${geo0.arrange.offset}`);

  await req("transport.record", {});
  await sleep(6000);
  const mid = await req("debug.followPlayhead", {});
  await req("transport.stop", {});
  console.log(`  [MEASURED] isPlaying=${mid.isPlaying} enabled=${mid.enabled} ` +
    `scrolls=${mid.arrange.scrolls} offset=${mid.arrange.offset} ` +
    `suspended=${mid.arrange.suspended} offsetReports=${mid.arrange.offsetReports}`);
  await sleep(1200);
  return mid;
}

// D FIRST — the positive control for E's zero.
const armD = await followArm({ label: "D (follow ON — does a take scroll?)", follow: true });
const armE = await followArm({ label: "E (follow OFF — negative control)", follow: false });

// Restore the sticky slots.
await req("debug.panelLayout", { followPlayhead: priorLayout.followPlayhead });
await req("debug.arrangeZoom", { ppb: priorZoom.ppb });
const restored = await req("debug.panelLayout", {});
const restoredZoom = await req("debug.arrangeZoom", {});
console.log(`\nrestored sticky slots: followPlayhead=${restored.followPlayhead} arrangePPB=${restoredZoom.ppb}`);

console.log("\n[SUMMARY premise 2]");
console.log(`  D (follow ON):  scrolls=${armD.arrange.scrolls} offset=${armD.arrange.offset}`);
console.log(`  E (follow OFF): scrolls=${armE.arrange.scrolls} offset=${armE.arrange.offset}`);

stopStaging(GATE);
console.log("\nPROBE COMPLETE — nothing asserted, everything printed.");
