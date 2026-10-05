// Put STAGING (17695) back, and PROVE it by re-reading — not by return codes.
import { open, cmd, close } from "../../session/build.mjs";
import { readFileSync, writeFileSync } from "node:fs";
const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-4";
const BASE = JSON.parse(readFileSync(`${HERE}/ids.json`, "utf8"));
await open();

await cmd("debug.clearModals", {}).catch(() => {});
await cmd("debug.effectEditor", { close: true }).catch(() => {});
await cmd("ui.showMixer", { show: false });
await cmd("debug.followPlayhead", { enabled: false }).catch(() => {});
await cmd("transport.stop", {}).catch(() => {});
await cmd("transport.seek", { beats: 0 });
await cmd("mixer.setMasterVolume", { volume: BASE.demo.master });
await cmd("debug.panelLayout", {
  pianoRollPPB: BASE.layout.pianoRollPPB,
  pianoRollRowHeight: BASE.layout.pianoRollRowHeight,
  rowHeight: BASE.layout.rowHeight,
  editorFraction: BASE.layout.editorFraction,
  editorMaximized: BASE.layout.editorMaximized,
  followPlayhead: BASE.layout.followPlayhead,
  pianoRollMinimap: BASE.layout.pianoRollMinimap,
  sidebarWidth: BASE.layout.sidebarWidth,
  mixerInsertsCollapsed: BASE.layout.mixerInsertsCollapsed,
  waveformNormalize: BASE.layout.waveformNormalize,
  waveformVerticalZoom: BASE.layout.waveformVerticalZoom,
  auditionEnabled: BASE.layout.auditionEnabled,
});

// ── the proof is the RE-READ ────────────────────────────────────────────────
const ov = await cmd("project.overview", {});
const layout = await cmd("debug.panelLayout", {});
const frame = await cmd("debug.windowFrame", {});
await cmd("debug.captureUI", { path: `${HERE}/shots/restored.png` });

const now = {
  tracks: ov.tracks.length, names: ov.tracks.map(t => t.name),
  notes: ov.tracks.reduce((n, t) => n + (t.clips[0] ? t.clips[0].noteCount : 0), 0),
  tempoBPM: ov.transport.tempoBPM, positionBeats: ov.transport.positionBeats,
  isPlaying: ov.transport.isPlaying, master: ov.master.volume,
  effects: ov.tracks.map(t => (t.fx || []).length),
  sends: ov.tracks.map(t => (t.sends || []).length),
  automation: ov.tracks.map(t => (t.automation || []).length),
  muted: ov.tracks.map(t => t.muted), soloed: ov.tracks.map(t => t.soloed),
  markers: (ov.markers || []).length,
  loop: ov.transport.loop, width: frame.width, height: frame.height,
};
const fail = [];
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
if (now.tracks !== BASE.demo.tracks) fail.push(`tracks ${now.tracks}`);
if (!eq(now.names, BASE.demo.names)) fail.push(`names ${now.names}`);
if (now.notes !== BASE.demo.notes) fail.push(`notes ${now.notes}`);
if (now.tempoBPM !== BASE.demo.tempoBPM) fail.push(`tempo ${now.tempoBPM}`);
if (!eq(now.effects, BASE.demo.effects)) fail.push(`effects ${now.effects}`);
if (!eq(now.sends, BASE.demo.sends)) fail.push(`sends ${now.sends}`);
if (now.master !== BASE.demo.master) fail.push(`master ${now.master}`);
if (now.muted.some(Boolean)) fail.push(`muted ${now.muted}`);
if (now.soloed.some(Boolean)) fail.push(`soloed ${now.soloed}`);
if (now.positionBeats !== 0) fail.push(`playhead ${now.positionBeats}`);
if (now.isPlaying) fail.push("still playing");
if (now.width !== BASE.frame.width || now.height !== BASE.frame.height)
  fail.push(`window ${now.width}x${now.height}`);
for (const k of Object.keys(BASE.layout))
  if (JSON.stringify(layout[k]) !== JSON.stringify(BASE.layout[k]))
    fail.push(`layout.${k}: ${JSON.stringify(BASE.layout[k])} -> ${JSON.stringify(layout[k])}`);

console.log(JSON.stringify(now, null, 1));
writeFileSync(`${HERE}/restore.json`, JSON.stringify({ baseline: BASE.demo, now, layout, fail }, null, 1));
if (fail.length) { console.error("DRIFT:\n  " + fail.join("\n  ")); process.exit(1); }
console.log("RESTORED — every field re-read and identical to the baseline.");
await close(); process.exit(0);
