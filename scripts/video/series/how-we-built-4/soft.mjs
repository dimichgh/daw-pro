// A BED, not a groove: the same project with Drums and Lead excluded, so an
// explanation is not competing with a beat. ⚠ STAGING ONLY (17695).
import { open, cmd, close } from "../../session/build.mjs";
import { readFileSync } from "node:fs";
const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-4";
await open();
const T = JSON.parse(readFileSync(`${HERE}/ids.json`, "utf8")).ids;
const r = await cmd("render.mixdown", { path: `${HERE}/audio/soft.wav`, fromBeat: 0,
  durationSeconds: 20.0, bitDepth: 24, excludeTrackIds: [T["Drums"], T["Lead"]] });
console.log("soft ->", r.path, r.durationSeconds, "s", JSON.stringify(r.excludedTracks || []));
await close(); process.exit(0);
