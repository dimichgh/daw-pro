// Put the staging app back the way it was found, and PROVE it by re-reading.
// ⚠ STAGING ONLY (17695). Recorded before anything was touched, 2026-09-05:
//   panelLayout  pianoRollPPB 32, pianoRollRowHeight 14, rowHeight 50,
//                editorFraction 0.45, editorMaximized false, followPlayhead
//                false, pianoRollMinimap true, sidebarWidth 260,
//                mixerInsertsCollapsed false, waveformNormalize true,
//                waveformVerticalZoom 1, auditionEnabled true
//   windowFrame  1600x900  (⛔ NOT resized by this build)
//   project      4 tracks (Pad/Bass/Drums/Lead), 64-beat clips of
//                48/80/174/16 notes, master 1, loop DISABLED 0..16, saved to
//                <scratchpad>/hwb2-staging-preexisting-2026-09-05.dawproj
import { open, cmd, close } from "../../session/build.mjs";

const PRE = process.env.PREEXISTING ||
  "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/" +
  "b1758ed8-13eb-4d9e-a984-4f35f1dff02d/scratchpad/" +
  "hwb2-staging-preexisting-2026-09-05.dawproj";

await open();
await cmd("debug.clearModals", {}).catch(() => {});
await cmd("ui.showMixer", { show: false });
await cmd("project.open", { path: PRE, discardChanges: true });
await cmd("mixer.setMasterVolume", { volume: 1 });
await cmd("debug.followPlayhead", { enabled: false }).catch(() => {});
await cmd("debug.panelLayout", {
  pianoRollPPB: 32, pianoRollRowHeight: 14, rowHeight: 50,
  editorFraction: 0.45, editorMaximized: false, followPlayhead: false,
  pianoRollMinimap: true, sidebarWidth: 260, mixerInsertsCollapsed: false,
  waveformNormalize: true, waveformVerticalZoom: 1, auditionEnabled: true,
});
await cmd("transport.seek", { beats: 0 });

// ⚠ A SETTER'S RETURN IS NOT PROOF IT TOOK. Read everything back.
const pl = await cmd("debug.panelLayout", {});
const wf = await cmd("debug.windowFrame", {});
const ov = await cmd("project.overview", {});
const want = { pianoRollPPB: 32, pianoRollRowHeight: 14, rowHeight: 50,
               editorFraction: 0.45, editorMaximized: false,
               followPlayhead: false, pianoRollMinimap: true,
               sidebarWidth: 260, mixerInsertsCollapsed: false,
               waveformNormalize: true, waveformVerticalZoom: 1,
               auditionEnabled: true };
const drift = Object.entries(want).filter(([k, v]) => pl[k] !== v)
                    .map(([k, v]) => `${k}: want ${v}, got ${pl[k]}`);
if (wf.width !== 1600 || wf.height !== 900) drift.push(`window ${wf.width}x${wf.height}`);
if (ov.tracks.length !== 4) drift.push(`tracks ${ov.tracks.length}, want 4`);
if (ov.master.volume !== 1) drift.push(`master ${ov.master.volume}`);
if (ov.transport.positionBeats !== 0) drift.push(`playhead ${ov.transport.positionBeats}`);
if (ov.transport.isPlaying) drift.push("still playing");
const notes = ov.tracks.map((t) => `${t.name}:${t.clips.reduce((a, c) => a + (c.noteCount || 0), 0)}`);
console.log(`tracks ${notes.join(", ")}  tempo ${ov.transport.tempoBPM}  ` +
            `master ${ov.master.volume}  window ${wf.width}x${wf.height}  ` +
            `loop ${ov.transport.loop.enabled}`);
console.log(drift.length ? "⚠ DRIFT:\n  " + drift.join("\n  ") : "restored, verified by re-read");
await close();
if (drift.length) process.exit(1);
