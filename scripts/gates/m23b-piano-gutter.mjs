// m23-b piano-roll keyboard-gutter gate — the ivory retone + dual-ink fix.
//
// The gutter's own pitch extremes are NOT reachable in-app (128 rows x 14 pt =
// 1792 pt of content against ~1117 pt of screen, and the roll pins itself to
// the middle with `.defaultScrollAnchor(.center)`), so the full-range proof is
// the offscreen harness that renders the REAL KeyboardSidebar over all 128
// rows. What THIS gate proves is everything the harness can't: the gutter in
// situ — against the grid, the scrub strip, the velocity lane and the
// controller strip — in both densities, and that note blocks still read over
// both lane tones.
//
// CAPTURE-ONLY: no pass/fail assertions; every frame is for pixel review.
// Staging: DAW_CONTROL_PORT=17695 ONLY (17600 is the user's live app).
// Usage: node m23b-gate.mjs <ABSOLUTE outdir> [prefix]
const PORT = process.env.PORT || "17695";
const OUT = process.argv[2];
const PREFIX = process.argv[3] || "m23b";
import fs from "fs";
const log = (s) => fs.writeSync(1, s + "\n");
fs.mkdirSync(OUT, { recursive: true });
let seq = 0;

function connect(timeoutMs = 5000) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
    const t = setTimeout(() => rej(new Error("connect timeout")), timeoutMs);
    ws.onopen = () => { clearTimeout(t); res(ws); };
    ws.onerror = () => { clearTimeout(t); rej(new Error("connect failed")); };
  });
}
function cmd(ws, command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = "m23b-" + (++seq);
    const t = setTimeout(() => rej(new Error(`TIMEOUT ${command}`)), timeoutMs);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== id) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id, command, params }));
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ws = await connect();
async function must(command, params) {
  const r = await cmd(ws, command, params);
  if (!r.ok) { log(`FAIL ${command}: ${JSON.stringify(r.error)}`); process.exit(1); }
  return r.result;
}
let clipId = null;
async function cap(name, extra = {}) {
  const p = { path: `${OUT}/${PREFIX}-${name}.png`, ...extra };
  if (clipId) p.selectClip = clipId;
  const r = await must("debug.captureUI", p);
  log(`  ${PREFIX}-${name}: ${r.width}x${r.height}`);
}

// ---- session ----
await must("project.new", { discardChanges: true });
const t1 = (await must("track.add", { kind: "instrument", name: "Lead Synth" })).id;
const clip = await must("clip.addMIDI", { trackId: t1, atBeat: 0, lengthBeats: 8 });
clipId = clip.id;

// Notes deliberately straddling BOTH lane tones and the white|white seams:
// E4/F4 (the E|F gap) and B4/C5 (the B|C gap) are adjacent white keys, and
// C#4/D#4/F#4/A#4 are the black lanes. A chromatic run through middle C proves
// note-block legibility over every lane tone in one frame.
const notes = [];
for (let i = 0; i < 16; i++) {
  notes.push({ pitch: 56 + i, startBeat: i * 0.5, lengthBeats: 0.45, velocity: 40 + i * 5 });
}
// A held chord on the two white|white seams, at the low-velocity end (the
// dimmest pill the grid ever has to carry).
for (const p of [64, 65, 71, 72]) {
  notes.push({ pitch: p, startBeat: 0, lengthBeats: 8, velocity: 32 });
}
await must("clip.setNotes", { clipId, notes });
// A controller lane so the CTRL strip renders (its left cell is one of the
// three seams where the ivory column now ends).
await must("clip.setControllerLane", {
  clipId, type: "cc", controller: 1,
  points: [ { beat: 0, value: 20 }, { beat: 4, value: 100 }, { beat: 8, value: 60 } ],
});

await must("debug.panelLayout", { reset: true });
await must("debug.windowFrame", { width: 1440, height: 900 });
await sleep(400);

// 1. Pro, default zoom — the reference frame (gutter + grid + scrub strip +
//    velocity lane + controller strip all in one).
await must("debug.panelDensity", { panel: "pianoRoll", mode: "pro" });
await sleep(400);
await cap("pro-default");

// 2. Editor pushed tall — the widest pitch window the app can show, so the
//    ivory column is judged over as many octaves as the viewport allows.
await must("debug.panelLayout", { editorFraction: 0.9 });
await sleep(400);
await cap("pro-tall");

// 3. Zoom extremes: the gutter is zoom-invariant, the GRID is not — this is
//    the note-block-over-both-lane-tones check at both ends of the ladder.
await must("debug.panelLayout", { editorFraction: 0.62, pianoRollPPB: 8 });
await sleep(400);
await cap("pro-zoomout");
await must("debug.panelLayout", { pianoRollPPB: 120 });
await sleep(400);
await cap("pro-zoomin");
await must("debug.panelLayout", { pianoRollPPB: 32 });
await sleep(300);

// 4. Transport parked INSIDE the clip: the cyan playhead must still read as
//    the one active-state accent now that middle C no longer wears cyan.
await must("transport.seek", { beats: 3.25 });
await sleep(400);
await cap("pro-playhead");

// 5. Simple density (no velocity lane / no snap picker) — same gutter.
await must("debug.panelDensity", { panel: "pianoRoll", mode: "simple" });
await sleep(400);
await cap("simple-default");

// 6. Window floor — the gutter at the smallest layout the app allows.
await must("debug.windowFrame", { width: 1208, height: 640 });
await sleep(400);
await cap("simple-floor");
await must("debug.panelDensity", { panel: "pianoRoll", mode: "pro" });
await sleep(400);
await cap("pro-floor");

log("done");
ws.close();
process.exit(0);
