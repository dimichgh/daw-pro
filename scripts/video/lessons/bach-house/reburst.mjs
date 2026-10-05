// Re-shoot ONLY the bursts. Renders are already on disk and must not be
// repeated: see shoot.mjs's header — a soundBank instrument renders SILENT once
// the transport has been run, so nothing may be bounced after this point anyway.
//
// ⚠ WHY THIS EXISTS: the first take's arrange bursts left the note editor
// scrolled to D6/G#5 from the last piano-roll STILL, so the bottom 40% of every
// layer chapter was an empty grid. Found by looking at frame 1. This points the
// editor at the Prelude clip, whole-clip zoom, centred on its median pitch,
// BEFORE the bursts run.
import { open, cmd, close, burst } from "../../session/build.mjs";
import * as M from "./material.mjs";
await open();
const ov = await cmd("project.overview", {});
const prelude = ov.tracks.find((t) => t.name === "Prelude");
await cmd("transport.setTempo", { bpm: M.BPM_HOUSE });
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.42,
                                 pianoRollPPB: 12, pianoRollRowHeight: 11,
                                 pianoRollMinimap: true });
await cmd("debug.captureUI", { path: "/dev/null", selectClip: prelude.clips[0].id });
await cmd("debug.panelLayout", { pianoRollCenterPitch: 70 });
await burst("pianoplay", 13.0, 0);
// ⭐ AND THE SAME PASSAGE AT BACH'S TEMPO, because chapter 02 plays piano72.wav
// and the footage under a play segment has to BE the passage being played. A
// 124 BPM burst under a 72 BPM render puts the playhead in the wrong place for
// thirteen seconds and nothing in the pipeline can see it.
await cmd("transport.setTempo", { bpm: M.BPM_BACH });
await burst("piano72play", 13.0, 0);
await cmd("transport.setTempo", { bpm: M.BPM_HOUSE });
for (const [name, beat] of [["kickplay", (M.ENTRY.kick - 1) * 4],
                            ["hatsplay", (M.ENTRY.hats - 1) * 4],
                            ["clapplay", (M.ENTRY.clap - 1) * 4],
                            ["bassplay", (M.ENTRY.bass - 1) * 4]])
  await burst(name, 13.0, beat, { arrange: true });
await cmd("mixer.setMasterVolume", { volume: 1 });
await cmd("transport.seek", { beats: 0 });
await close();
