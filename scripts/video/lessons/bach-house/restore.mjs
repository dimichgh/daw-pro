// Put staging (17695) back exactly as it was found, and PROVE it by re-reading.
// ⚠ The panel layout values below were READ from the app before any of this
// film's work touched it; they are not defaults.
import { open, cmd, close } from "../../session/build.mjs";
const BEFORE = {
  pianoRollPPB: 32, pianoRollRowHeight: 14, rowHeight: 50, editorFraction: 0.45,
  editorMaximized: false, followPlayhead: false, pianoRollMinimap: true,
  sidebarWidth: 260, waveformNormalize: true, waveformVerticalZoom: 1,
  mixerInsertsCollapsed: false, auditionEnabled: true,
};
const path = process.argv[2];
if (!path) { console.error("usage: node restore.mjs <staging-before-bach.dawproj>"); process.exit(1); }
await open();
const r = await cmd("project.open", { path, discardChanges: true });
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", BEFORE);
await cmd("transport.seek", { beats: 0 });
await cmd("mixer.setMasterVolume", { volume: 1 });
const ov = await cmd("project.overview", {});
const lay = await cmd("debug.panelLayout", {});
console.log("warnings:", JSON.stringify(r.warnings ?? []));
console.log("tempo:", ov.transport.tempoBPM, "playhead:", ov.transport.positionBeats,
            "master:", JSON.stringify(ov.master));
console.log("tracks:", ov.tracks.map((t) => `${t.name}(${t.clips.length} clips, `
            + `${t.clips.reduce((a, c) => a + (c.noteCount ?? 0), 0)} notes, fx ${t.fx.length})`).join(" | "));
let drift = [];
for (const [k, v] of Object.entries(BEFORE)) if (lay[k] !== v) drift.push(`${k}: ${lay[k]} != ${v}`);
console.log(drift.length ? "LAYOUT DRIFT: " + drift.join(", ") : "layout restored, field for field");
await close();
