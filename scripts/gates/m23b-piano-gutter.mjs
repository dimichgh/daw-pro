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
// Staging: this gate BUILDS AND LAUNCHES its own app on 17695 — just run
// `node scripts/gates/m23b-piano-gutter.mjs`. 17600 is the user's LIVE app and
// the harness refuses it outright.
//
// >>> THE `PORT` OVERRIDE IS GONE, AND IT WAS THE DANGEROUS KIND (m23-ac-3c) <<<
// This file used to read `process.env.PORT || "17695"` under a header claiming
// `DAW_CONTROL_PORT=17695 ONLY`. The documented variable did nothing; the one it
// actually honoured, `PORT`, is among the most commonly-exported names in any
// shell, so a stray `PORT=17600` aimed this gate at the user's live session —
// where its first command is `project.new {discardChanges: true}`. No override
// now; `assertStagingPort` refuses 17600 structurally.
//
// Usage: node m23b-piano-gutter.mjs [ABSOLUTE outdir] [prefix]
//   The outdir arg still works and is resolved by the APP against ITS cwd, so
//   pass an absolute path. Omitted, it defaults to the staging out dir.
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";

const GATE = "m23b";                                  // names the pidfile + out dir
const OUT = process.argv[2] || `/tmp/daw-gate-out/${GATE}`;
const PREFIX = process.argv[3] || "m23b";
const log = (s) => fs.writeSync(1, s + "\n");
fs.mkdirSync(OUT, { recursive: true });
let seq = 0;

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

buildOrAbort({ label: "building staging binary (m23b)…" });
startStaging({ gate: GATE });
// A true drop-in HERE, unlike m18c/m19f: cmd() attaches its own per-call `message`
// listener and removes it on reply, so there is no shared reply pump on the socket
// to preserve. The harness also retries 40x1 s rather than failing after a single
// 5 s attempt — the right budget against a cold boot we now own.
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

// ── m23-dv-1: this gate leaked `editorFraction` into the shared DAWApp domain ──
// MEASURED from a seeded app-defaults baseline: after a full green run the domain
// held `editorFraction=0.55` against a default of 0.45. ⚠️ The gate never writes
// 0.55 — it asks for 0.9 (step 2) and 0.62 (step 3), and BOTH are outside
// `PanelLayoutStore.editorFractionRange` (0.30...0.55) and clamp to the ceiling.
// So the leaked value cannot be found by grepping the gate for it, and a "restore"
// that wrote back the REQUESTED value would also be wrong. Read the prior and put
// THAT back.
//
// ⚠️ Read BEFORE the `{reset:true}` below — reset is itself a write, and a prior
// captured after it is the default, not the user's value.
const priorLayout = await must("debug.panelLayout", {});
console.log(`prior panelLayout: editorFraction=${priorLayout.editorFraction} `
  + `pianoRollPPB=${priorLayout.pianoRollPPB} rowHeight=${priorLayout.rowHeight} `
  + `sidebarWidth=${priorLayout.sidebarWidth}`);

let layoutRestored = false;
async function restoreLayout(reason) {
  if (layoutRestored) return;          // idempotent: normal path AND handlers call it
  layoutRestored = true;
  try {
    await cmd(ws, "debug.panelLayout", {
      editorFraction: priorLayout.editorFraction,
      pianoRollPPB: priorLayout.pianoRollPPB,
      rowHeight: priorLayout.rowHeight,
      sidebarWidth: priorLayout.sidebarWidth,
    });
    const back = await cmd(ws, "debug.panelLayout", {});
    console.log(`  panelLayout restored (${reason}): `
      + `editorFraction=${back.result?.editorFraction} pianoRollPPB=${back.result?.pianoRollPPB}`);
  } catch (e) {
    console.error(`  ⚠️ panelLayout RESTORE FAILED (${reason}) — LEAKED: ${e?.message ?? e}`);
  }
}
for (const sig of ["unhandledRejection", "uncaughtException"]) {
  process.on(sig, async (err) => {
    console.error(`\n${sig.toUpperCase()} — restoring panelLayout before exit:`, err);
    await restoreLayout(sig);
    stopStaging(GATE);
    process.exit(3);
  });
}
// ⚠️ NOT restored here and NOT this item's scope: this gate also sets
// `debug.panelDensity {panel:"pianoRoll", mode:"pro"}` and never puts it back —
// that is the m23-ej-2 class, which has its own sweep and its own verification
// plan. Fixing it here would land it outside that item's leg-for-leg comparison.

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

// m23-dv-1: restore BEFORE teardown — after stopStaging there is nobody to ask.
await restoreLayout("normal exit");
stopStaging(GATE);   // SIGTERMs by exact pid AND releases our session.lock
log("done");
ws.close();
process.exit(0);
