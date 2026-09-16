// Put the staging app back the way it was found.
//
// ⚠ THE PANEL LAYOUT WAS READ BEFORE ANYTHING WAS CHANGED, so this restores the
// USER'S values, not the app defaults:
//   {"pianoRollRowHeight":14,"pianoRollPPB":32,"rowHeight":50,
//    "editorFraction":0.45,"editorMaximized":false,"followPlayhead":false,
//    "pianoRollMinimap":true,"waveformNormalize":true,"sidebarWidth":260,
//    "mixerInsertsCollapsed":false,"auditionEnabled":true,
//    "waveformVerticalZoom":1}
// `pianoRollCenterPitch` is a one-shot scroll request, not persisted state, so
// there is nothing to put back for it.
import { open, cmd, close } from "../../session/build.mjs";
const BEFORE = process.argv[2];
await open();
await cmd("debug.samplerEditor", { close: true }).catch(() => {});
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", {
  pianoRollPPB: 32, pianoRollRowHeight: 14, editorFraction: 0.45,
  editorMaximized: false, followPlayhead: false, pianoRollMinimap: true,
});
await cmd("mixer.setMasterVolume", { volume: 1 });
await cmd("transport.stop", {}).catch(() => {});
await cmd("transport.seek", { beats: 0 });
const r = await cmd("project.open", { path: BEFORE, discardChanges: true });
const ov = await cmd("project.overview", {});
const pl = await cmd("debug.panelLayout", {});
console.log("warnings", JSON.stringify(r.warnings ?? r.snapshot?.warnings ?? []));
console.log("tempo", ov.transport?.tempoBPM, "master", ov.master?.volume,
            "playhead", ov.transport?.positionBeats);
console.log("tracks", (ov.tracks || []).map((t) => t.name).join(" / "));
console.log("layout", JSON.stringify(pl));
close(); process.exit(0);
