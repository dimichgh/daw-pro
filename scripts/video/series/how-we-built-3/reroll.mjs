import { open, cmd } from "../../session/build.mjs";
import { readFileSync } from "node:fs";
const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-3";
const T = JSON.parse(readFileSync(`${HERE}/ids.json`, "utf8")).ids;
await open();
await cmd("debug.panelLayout", { pianoRollPPB: 26, pianoRollRowHeight: 13,
                                pianoRollMinimap: true, editorFraction: 0.62 });
await cmd("debug.captureUI", { path: `${HERE}/shots/app-roll.png`, selectClip: T["Lead:clip"] });
await cmd("debug.panelLayout", { pianoRollCenterPitch: 68 });
await cmd("debug.captureUI", { path: `${HERE}/shots/app-roll.png`, selectClip: T["Lead:clip"] });
await cmd("debug.panelLayout", { editorFraction: 0.30, pianoRollPPB: 32, pianoRollRowHeight: 14 });
console.log("ok");
process.exit(0);
