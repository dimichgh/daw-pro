// Stills for Part 4. ⚠ STAGING ONLY (17695).
//
// ⚠ TWO THINGS LEARNED HERE THE HARD WAY, BOTH SILENT:
//  1. build.mjs's shot() helper passes a RELATIVE path to debug.captureUI, and
//     the APP resolves it against ITS OWN cwd (the repo root), not the caller's.
//     Every capture below uses an absolute path.
//  2. The piano roll shows a fixed pitch band. MEASURED with clip.getNotes:
//     Bass 29..43 (median 33), Pad 53..67 (median 60), Lead 67..76.
//     The Bass photographed as an almost-empty grid until it was centred.
import { open, cmd, close } from "../../session/build.mjs";
import { readFileSync } from "node:fs";
const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-4";
await open();
const T = JSON.parse(readFileSync(`${HERE}/ids.json`, "utf8")).ids;
const layout = (o) => cmd("debug.panelLayout", o);
const cap = (n, extra = {}) => cmd("debug.captureUI", { path: `${HERE}/shots/${n}.png`, ...extra });

await cmd("debug.clearModals", {}).catch(() => {});
await cmd("ui.showMixer", { show: false });
await layout({ editorMaximized: false, editorFraction: 0.30, followPlayhead: false });
await cmd("transport.seek", { beats: 0 });
await cap("app-arrange");

await layout({ pianoRollPPB: 26, pianoRollRowHeight: 13, pianoRollMinimap: true,
               editorFraction: 0.62 });
await cap("app-roll-pad",  { selectClip: T["Pad:clip"] });
await layout({ pianoRollCenterPitch: 60 });
await cap("app-roll-pad",  { selectClip: T["Pad:clip"] });
await cap("app-roll-bass", { selectClip: T["Bass:clip"] });
await layout({ pianoRollCenterPitch: 36 });
await cap("app-roll-bass", { selectClip: T["Bass:clip"] });

await layout({ editorMaximized: false, editorFraction: 0.30, pianoRollPPB: 32,
               pianoRollRowHeight: 14, pianoRollCenterPitch: 60 });
await cmd("transport.seek", { beats: 0 });
await cap("app-arrange2");
console.log("shots done");
await close();
process.exit(0);
