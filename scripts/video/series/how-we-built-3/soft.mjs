import { open, cmd } from "../../session/build.mjs";
import { readFileSync } from "node:fs";
const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-3";
const T = JSON.parse(readFileSync(`${HERE}/ids.json`, "utf8")).ids;
await open();
const r = await cmd("render.mixdown", {
  path: `${HERE}/audio/soft.wav`, fromBeat: 0, durationSeconds: 20.0, bitDepth: 24,
  excludeTrackIds: [T["Drums"], T["Lead"]],
});
console.log("soft", r.path, r.durationSeconds, r.excludedTracks || "");
process.exit(0);
