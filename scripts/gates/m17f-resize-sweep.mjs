// m17-f resize sweep — window-size x workspace x density capture matrix
// (debug.windowFrame; OS clamps HEIGHT to the display, width unclamped).
// CAPTURE-ONLY: no pass/fail assertions here — frames are for pixel review.
//
// Pass 1 (editor closed), 4 sizes x arrange-simple / arrange-pro / mix-simple
// / mix-pro. Pass 2 (piano roll open on the CC clip, Pro everywhere), 4 sizes
// x arrange-pro-editor, then the same with an effect-editor card open
// (arrange-pro-fxcard) — the fxcard leg switches workspaceMode to .mix
// (debug.effectEditor open does this BY DESIGN, Sources/DAWApp/DAWProApp.swift
// effectEditorDebug) and this script switches back to arrange after close so
// later legs frame what their name says. Resize via debug.windowFrame
// (AppleScript impossible on the unbundled staging binary — m17-b measured);
// settle ~300 ms after each stage. Pairs with the barline detector at
// scripts/gates/m17f-barlines-detector.swift (a separate file, not below this one).
//
// >>> THIS GATE NOW SEEDS ITS OWN FIXTURE, AND THAT IS THE WHOLE POINT (m23-ac-3e-1) <<<
//
// It used to be the ONLY gate in the corpus that never called `project.new`. It
// read the CC clip id, EQ track id and EQ effect id from argv[3..5] and skipped
// pass 2 entirely when they were absent — so the ordinary invocation
//     node m17f-resize-sweep.mjs /tmp/out
// produced 16 frames, not the 24 this header describes, and said nothing about
// the third it had skipped. The 24-frame runs in the m18-f / m19-h records
// happened only because an operator hand-staged a clip and an EQ by hand and
// passed the ids. A skipped leg that is indistinguishable from a passed one is
// the m23-bj defect class; the fix is to make the fixture unconditional.
//
// The fixture below is RECOVERED, not invented: the m18-f close record describes
// the staging its 24 clean frames were taken against — "8-beat clip, notes incl.
// a beat-9 latent, Mod CC in-clip + beyond". Both out-of-clip cases were probed
// against a live instance before this was written: `clip.setNotes` keeps a note
// at beat 9 on a length-8 clip and `clip.setControllerLane` keeps CC points at
// beats 8 and 12, so the latent/ghost rendering the sweep exists to frame is
// really on screen (verified by project.snapshot read-back, m23-ac-3e-1).
//
// >>> THE `PORT` OVERRIDE IS GONE, AND IT WAS A LIVE ROUTE TO 17600 (m23-bi) <<<
// This file used to read `process.env.PORT || "17695"` under a header that said
// `Staging: DAW_CONTROL_PORT=17695`. Both halves were wrong: the documented
// variable did nothing, and the undocumented one — `PORT`, among the most
// commonly exported names in any shell — genuinely built the WebSocket URL. So
// `PORT=17600` pointed a 24-step resize sweep at the user's real session and
// resized their window out from under them. The port now comes from the harness
// and `assertStagingPort` refuses 17600 structurally.
//
// Staging: this gate BUILDS AND LAUNCHES its own app on 17695 — just run
//   node scripts/gates/m17f-resize-sweep.mjs [outdir]
//   outdir defaults to /tmp/daw-gate-out/m17f
// Exit codes: 0 = sweep completed; 1 = a wire command failed.
// Promoted from session scratchpad 2026-07-16 (m17-g); self-seeding 2026-07-30.
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";

const GATE = "m17f";                       // names the pidfile + staging out dir
const OUT = process.argv[2] || `/tmp/daw-gate-out/${GATE}`;
fs.mkdirSync(OUT, { recursive: true });
let seq = 0;

function cmd(ws, command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = "swp-" + (++seq);
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

buildOrAbort({ label: "building staging binary (m17f)…" });
startStaging({ gate: GATE });
// Swapping the old local connect() for the harness one is a true drop-in here:
// cmd() attaches its own per-call `message` listener and removes it on reply, so
// there is no shared reply pump on this socket to preserve.
const ws = await connect();

async function must(command, params) {
  const r = await cmd(ws, command, params);
  if (!r.ok) {
    console.error(`FAIL ${command}: ${JSON.stringify(r.error)}`);
    // Abrupt exit — teardown is structural via armTeardown (m23-bd), so the
    // staging app is still SIGTERMed by exact pid and the session lock released.
    process.exit(1);
  }
  return r.result;
}
async function cap(name) {
  const r = await must("debug.captureUI", { path: `${OUT}/${name}.png` });
  console.log(`${name}: ${r.width}x${r.height}`);
}

// ---- fixture ---------------------------------------------------------------
// The state every leg below frames. Seeded once, unconditionally: pass 2 and the
// fxcard leg used to be optional, which is exactly how this gate came to report
// 24 legs and run 16.
async function seedFixture() {
  await must("project.new", { discardChanges: true });
  const synth = (await must("track.add", { kind: "instrument", name: "Lead Synth" })).id;
  const clip = await must("clip.addMIDI", { trackId: synth, atBeat: 0, lengthBeats: 8 });

  // A chromatic run for note-block legibility across every lane tone, a held
  // low-velocity chord (the dimmest pill the grid carries), and ONE note past
  // the clip end — legal-but-latent data that the out-of-clip shade must mark.
  const notes = [];
  for (let i = 0; i < 16; i++) {
    notes.push({ pitch: 56 + i, startBeat: i * 0.5, lengthBeats: 0.45, velocity: 40 + i * 5 });
  }
  for (const p of [64, 65, 71, 72]) {
    notes.push({ pitch: p, startBeat: 0, lengthBeats: 8, velocity: 32 });
  }
  notes.push({ pitch: 67, startBeat: 9, lengthBeats: 1, velocity: 96 });   // beat-9 latent
  await must("clip.setNotes", { clipId: clip.id, notes });

  // Mod (CC 1) in-clip AND beyond the end, so the CTRL strip renders both the
  // live trace and the m18-e ghost past the boundary hairline.
  await must("clip.setControllerLane", {
    clipId: clip.id, type: "cc", controller: 1,
    points: [{ beat: 0, value: 20 }, { beat: 4, value: 100 },
             { beat: 8, value: 60 }, { beat: 12, value: 5 }],
  });

  // A second track carrying the EQ the fxcard leg opens.
  const eqTrack = (await must("track.add", { kind: "audio", name: "Bass" })).id;
  const eqFx = (await must("fx.add", { trackId: eqTrack, kind: "eq" })).effectId;

  console.log(`# fixture: clip ${clip.id} on ${synth}; eq ${eqFx} on ${eqTrack}`);
  return { ccClip: clip.id, eqTrack, eqFx };
}

const { ccClip, eqTrack, eqFx } = await seedFixture();
await must("debug.panelLayout", { reset: true });

const sizes = [
  { name: "s1208x760", w: 1200, h: 760 },   // clamps to the 1208 floor width
  { name: "s1440x900", w: 1440, h: 900 },
  { name: "s1728x1080", w: 1728, h: 1080 },
  { name: "smax", w: 3456, h: 2234 },        // echo reports the real landing size
];

// ---- pass 1: editor closed ----
for (const s of sizes) {
  const f = await must("debug.windowFrame", { width: s.w, height: s.h });
  await sleep(350);
  console.log(`# size ${s.name} -> ${f.width}x${f.height}`);
  await must("ui.showMixer", { show: false });
  await must("debug.panelDensity", { panel: "arrange", mode: "simple" });
  await must("debug.panelDensity", { panel: "transport", mode: "simple" });
  await sleep(300);
  await cap(`${s.name}-arr-simple`);
  await must("debug.panelDensity", { panel: "arrange", mode: "pro" });
  await must("debug.panelDensity", { panel: "transport", mode: "pro" });
  await sleep(300);
  await cap(`${s.name}-arr-pro`);
  await must("ui.showMixer", { show: true });
  await must("debug.panelDensity", { panel: "mixer", mode: "simple" });
  await sleep(300);
  await cap(`${s.name}-mix-simple`);
  await must("debug.panelDensity", { panel: "mixer", mode: "pro" });
  await sleep(300);
  await cap(`${s.name}-mix-pro`);
}

// ---- pass 2: piano roll open (CC clip), Pro everywhere ----
// No longer conditional: the fixture above guarantees the clip and the EQ exist.
await must("ui.showMixer", { show: false });
await must("debug.panelDensity", { panel: "pianoRoll", mode: "pro" });
for (const s of sizes) {
  const f = await must("debug.windowFrame", { width: s.w, height: s.h });
  await sleep(350);
  console.log(`# size ${s.name} -> ${f.width}x${f.height}`);
  // selectClip opens the piano roll and leaves it open
  await must("debug.captureUI", { path: `${OUT}/tmp-select.png`, selectClip: ccClip });
  await sleep(300);
  await cap(`${s.name}-arr-pro-editor`);
  await must("debug.effectEditor", { trackId: eqTrack, effectId: eqFx, open: true });
  await sleep(300);
  await cap(`${s.name}-arr-pro-fxcard`);
  await must("debug.effectEditor", { close: true });
  // close does NOT revert workspaceMode (effectEditorDebug's close path
  // only clears effectEditorTarget/effectEditor — it never touches
  // workspaceMode). open:true forced .mix; switch back to arrange the
  // same way pass 1 does, or every later *-arr-pro-editor leg lies.
  await must("ui.showMixer", { show: false });
  await sleep(200);
}
fs.rmSync(`${OUT}/tmp-select.png`, { force: true });

console.log("sweep done");
stopStaging(GATE);   // SIGTERMs by exact pid AND releases our session.lock
ws.close();
process.exit(0);
