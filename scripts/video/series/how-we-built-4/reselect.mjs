// The ONE field restore.mjs could not check, because I never recorded it: the
// SELECTED CLIP. The baseline capture (shots/app-arrange.png, taken before
// anything was changed) shows the editor open on "Lead"; shoot.mjs then aimed
// it at the Bass and nothing aimed it back. Recorded here rather than left
// unsaid, and corrected.
import { open, cmd, close } from "../../session/build.mjs";
import { readFileSync } from "node:fs";
const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-4";
const T = JSON.parse(readFileSync(`${HERE}/ids.json`, "utf8")).ids;
await open();
await cmd("debug.captureUI", { path: `${HERE}/shots/restored2.png`, selectClip: T["Lead:clip"] });
await cmd("debug.panelLayout", { editorFraction: 0.45, pianoRollPPB: 32,
                                 pianoRollRowHeight: 14, editorMaximized: false });
await cmd("transport.seek", { beats: 0 });
await cmd("debug.captureUI", { path: `${HERE}/shots/restored.png` });
const l = await cmd("debug.panelLayout", {});
console.log("layout after:", JSON.stringify(l));
await close(); process.exit(0);
