// Stills for "How We Built a DAW — Part 2".
// ⚠ STAGING ONLY (17695); build.mjs refuses 17600.
import { open, cmd, shot, close } from "../../session/build.mjs";
import { readFileSync } from "node:fs";

const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-2";
await open();
const T = JSON.parse(readFileSync(`${HERE}/ids.json`, "utf8")).ids;
const layout = (o) => cmd("debug.panelLayout", o);

await cmd("debug.clearModals", {}).catch(() => {});
await cmd("ui.showMixer", { show: false });
await layout({ editorMaximized: false, editorFraction: 0.30, followPlayhead: false });
await cmd("transport.seek", { beats: 0 });
await shot("app-arrange");

// the lead line's notes — used once, to say "this is the material you heard"
await layout({ pianoRollPPB: 26, pianoRollRowHeight: 13, pianoRollMinimap: true,
               editorFraction: 0.62 });
await cmd("debug.captureUI", { path: `${HERE}/shots/app-roll-lead.png`, selectClip: T["Lead:clip"] });
await layout({ pianoRollCenterPitch: 68 });
await cmd("debug.captureUI", { path: `${HERE}/shots/app-roll-lead.png`, selectClip: T["Lead:clip"] });

await layout({ editorMaximized: false, editorFraction: 0.30 });
await cmd("debug.clearModals", {}).catch(() => {});
await cmd("transport.seek", { beats: 0 });
await shot("app-arrange");
console.log("shots done");
await close();
