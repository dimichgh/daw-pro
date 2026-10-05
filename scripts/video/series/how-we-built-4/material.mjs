// Reads the demo project off STAGING (17695), saves whatever session is open
// there FIRST, pins ids, and renders the mix once.  Nothing is built: this is
// the same four-track hand-written project Parts 1-3 used.
import { open, cmd, close } from "../../session/build.mjs";
import { writeFileSync } from "node:fs";
const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-4";
const SCRATCH = process.env.SCRATCH;
await open();

// ⚠ SAVE THE PRE-EXISTING SESSION BEFORE TOUCHING ANYTHING.
const saved = await cmd("project.save", { path: `${SCRATCH}/hwb4-staging-preexisting-2026-09-05.dawproj` });
console.log("SAVED PRE-EXISTING SESSION ->", saved.path);

const ov = await cmd("project.overview", {});
const ids = {}; let notes = 0;
for (const t of ov.tracks) {
  ids[t.name] = t.id;
  if (t.clips[0]) { ids[`${t.name}:clip`] = t.clips[0].id; notes += t.clips[0].noteCount; }
}
const demo = { tracks: ov.tracks.length, notes, tempoBPM: ov.transport.tempoBPM,
               names: ov.tracks.map(t => t.name),
               effects: ov.tracks.map(t => (t.fx || []).length),
               sends: ov.tracks.map(t => (t.sends || []).length),
               master: ov.master.volume };
console.log(JSON.stringify(demo));

const layout = await cmd("debug.panelLayout", {});
const frame  = await cmd("debug.windowFrame", {});
console.log("LAYOUT", JSON.stringify(layout)); console.log("FRAME", JSON.stringify(frame));

const r = await cmd("render.mixdown", {
  path: `${HERE}/audio/mix-full.wav`, fromBeat: 0, durationSeconds: 20.0, bitDepth: 24 });
console.log("rendered", r.path, r.durationSeconds, "s");

const banks = await cmd("instrument.listSoundBanks", {}).catch(e => ({ error: String(e) }));
writeFileSync(`${HERE}/ids.json`, JSON.stringify({ ids, demo, render: r, layout, frame, banks }, null, 1));
console.log("BANKS", JSON.stringify(banks).slice(0, 1200));
await close();
