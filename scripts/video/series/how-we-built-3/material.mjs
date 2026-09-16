// Part 3 does not BUILD a project: the demo project from this series' own
// build already sits on staging (four instrument tracks, notes written by
// hand, no generation model anywhere near it). This reads it, pins its ids,
// and renders it once so the film has something honest to play.
//
// ⚠ STAGING ONLY (17695) — build.mjs refuses 17600 outright.
import { open, cmd, close } from "../../session/build.mjs";
import { writeFileSync } from "node:fs";

const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-3";
await open();
const ov = await cmd("project.overview", {});
const ids = {};
let notes = 0;
for (const t of ov.tracks) {
  ids[t.name] = t.id;
  if (t.clips[0]) { ids[`${t.name}:clip`] = t.clips[0].id; notes += t.clips[0].noteCount; }
}
const demo = {
  tracks: ov.tracks.length,
  notes,
  tempoBPM: ov.transport.tempoBPM,
  names: ov.tracks.map((t) => t.name),
};
console.log(demo);

// One offline render. ⚠ A WINDOWED render drops MIDI notes whose note-on is
// before the window, so this renders from beat 0 and the excerpt is cut later.
const r = await cmd("render.mixdown", {
  path: `${HERE}/audio/mix-full.wav`, fromBeat: 0, durationSeconds: 20.0, bitDepth: 24,
});
console.log("rendered", r.path, r.durationSeconds, "s");
writeFileSync(`${HERE}/ids.json`, JSON.stringify({ ids, demo, render: r }, null, 1));
await close();
