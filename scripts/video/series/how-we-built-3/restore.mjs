// Put staging back exactly as it was found, then RE-READ to prove it.
// ⚠ STAGING ONLY (17695). A setter's return is not proof.
import { open, cmd } from "../../session/build.mjs";
const SP = "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/b1758ed8-13eb-4d9e-a984-4f35f1dff02d/scratchpad";
await open();
await cmd("debug.effectEditor", { close: true }).catch(() => {});
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", {
  pianoRollPPB: 32, pianoRollRowHeight: 14, rowHeight: 50, editorFraction: 0.45,
  editorMaximized: false, followPlayhead: false, pianoRollMinimap: true,
  sidebarWidth: 260, mixerInsertsCollapsed: false, waveformNormalize: true,
  waveformVerticalZoom: 1, auditionEnabled: true,
});
await cmd("transport.stop", {}).catch(() => {});
await cmd("transport.seek", { beats: 0 });
await cmd("mixer.setMasterVolume", { volume: 1 });
const ov = await cmd("project.overview", {});
const pl = await cmd("debug.panelLayout", {});
const wf = await cmd("debug.windowFrame", {});
console.log(JSON.stringify({
  tracks: ov.tracks.map((t) => [t.name, t.clips[0] && t.clips[0].noteCount, t.fx.length,
                                t.sends.length, t.automation.length]),
  tempo: ov.transport.tempoBPM, playhead: ov.transport.positionBeats,
  isPlaying: ov.transport.isPlaying, master: ov.master.volume,
  loop: ov.transport.loop, markers: ov.markerCount,
  layout: pl, window: [wf.width, wf.height],
}, null, 1));
await cmd("debug.captureUI", { path: `${SP}/hwb3-staging-after.png` });
process.exit(0);
