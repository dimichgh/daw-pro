#!/usr/bin/env node
// The transport driver for ONE screen take, in two calls so the slow part
// (opening a state, waiting for the note editor to read the take) is OVER
// before the camera rolls:
//
//   node record-motion.mjs prep <burst>   open the state, set the view, seek
//                                         PRE seconds before the excerpt, and
//                                         photograph the view (bursts/<b>/prep.png)
//   node record-motion.mjs play <seconds> play, PROVE the playhead moves, hold, stop
//
// The take's row comes from takes.json — the same row cut-loops.py cut the
// audio from — so picture and sound are the same bar by construction.
// ⚠ PRE, not a measured "handshake": record-all.sh reads the transport clock in
// each take's FIRST FRAME and trims the head to the excerpt's first sample, so
// sync is measured per take, not assumed from another film's constant.
//
// ⛔ Silent WITHOUT muting the master (a dead master fader is visible on
// screen): staging plays at unity into BlackHole 2ch, selected BY UID and
// read back (wire.mjs silence()).
import { readFileSync, mkdirSync } from "node:fs";
import { open, close, cmd, sleep, silence, VOICE_HOME } from "./wire.mjs";
import { openState, openEditor, pe } from "./states.mjs";
import { shot as rawShot } from "./shoot.mjs";

export const PRE = 2.5;
const [mode, arg] = process.argv.slice(2);
const T = JSON.parse(readFileSync(`${VOICE_HOME}/takes.json`, "utf8"));
const SPB = 60 / T.tempo;

await open();
try {
  if (mode === "prep") {
    const take = T.takes.find((t) => t.burst === arg);
    if (!take) throw new Error(`no take ${arg} in takes.json`);
    await silence();
    await cmd("mixer.setMasterVolume", { volume: 1 });
    await cmd("transport.stop");
    await openState(take.state);
    await cmd("view.panelLayout", { workspace: "arrange", editorMaximized: false });
    await cmd("debug.arrangeZoom", { ppb: 24, rowStep: "large" });
    const [kind, val, tool] = take.view.split(":");
    const ov = await cmd("project.overview", {});
    const clips = ov.tracks.flatMap((t) => (t.clips || []).map((c) => ({ ...c, track: t.name })));
    if (kind === "steps") {
      const b = Number(val);
      const c = clips.find((c) => c.track === "Drums" && b >= c.startBeat && b < c.startBeat + c.lengthBeats);
      if (!c) throw new Error(`no drum clip covers beat ${b}`);
      await cmd("view.selectClip", { clipId: c.id });
      await cmd("debug.stepSequencer", { mode: "steps" });
    } else if (kind === "roll") {
      const c = clips.find((c) => c.name === val);
      if (!c) throw new Error(`no clip named ${val}`);
      await cmd("view.selectClip", { clipId: c.id });
      await cmd("debug.stepSequencer", { mode: "notes" });
    } else if (kind === "editor") {
      const e = await openEditor({ rowHeight: Number(val) });
      await pe({ act: "clearSelection" });
      // The octave states sit low in a window fitted to the SUNG pitch: scroll
      // to the bottom so the moved notes, not their empty ghosts, fill the view.
      if (take.state.startsWith("octave")) await pe({ act: "scroll", y: Math.max(0, e.viewport.contentH - e.viewport.viewportH) });
      // "editor:14:voice" — the Voice tool's marks ("Deeper 6.0") are drawn only
      // while that tool is active. Without it the Voice A/B showed the SAME
      // picture in both halves and only the badge told them apart.
      if (tool) {
        const t = await pe({ act: "tool", tool });
        const marks = (t.voice?.marks || []).length;
        console.error(`tool ${tool}: ${marks} voice mark(s) drawn`);
      }
    } else if (kind === "arrange") {
      // The note editor is a LATCH (DAWProApp.swift closePitchEditor): opened
      // only explicitly, and it survives project.open when the clip id does.
      // Selecting any OTHER clip clears it, and an AUDIO clip opens no editor
      // of its own — so the harmony clip is selected, where there is one.
      const h = clips.find((c) => c.track.startsWith("Harmony"));
      if (h) await cmd("view.selectClip", { clipId: h.id });
    } else {
      throw new Error(`unknown view ${take.view}`);
    }
    const songStart = take.srcSong + take.start;
    const seekSec = Math.max(0, songStart - PRE);
    await cmd("transport.seek", { beats: seekSec / SPB });
    mkdirSync(`${VOICE_HOME}/bursts/${take.burst}`, { recursive: true });
    await sleep(600);
    await rawShot(`../../bursts/${take.burst}/prep`);
    console.log(JSON.stringify({ burst: take.burst, state: take.state, view: take.view, songStart, seekSec,
                                 recordSeconds: +(songStart - seekSec + take.len + 3.5).toFixed(2) }));
  } else if (mode === "play") {
    const hold = Number(arg);
    const pos = async () => (await cmd("project.overview", {})).transport;
    console.error(`play at ${new Date().toISOString()}`);
    await cmd("transport.play");
    const t0 = await pos();
    await sleep(1200);
    const t1 = await pos();
    if (!t1.isPlaying || t1.positionBeats <= t0.positionBeats) {
      await cmd("transport.stop");
      throw new Error(`TRANSPORT IS NOT MOVING: ${t0.positionBeats} -> ${t1.positionBeats}, isPlaying=${t1.isPlaying}`);
    }
    console.error(`moving: beat ${t0.positionBeats.toFixed(2)} -> ${t1.positionBeats.toFixed(2)}`);
    await sleep(Math.max(0, hold - 1.2) * 1000);
    await cmd("transport.stop");
  } else {
    throw new Error("usage: record-motion.mjs prep <burst> | play <seconds>");
  }
} catch (err) {
  console.error("⛔", err?.stack || err);
  process.exitCode = 1;
} finally {
  close();
  process.exit(process.exitCode ?? 0);
}
