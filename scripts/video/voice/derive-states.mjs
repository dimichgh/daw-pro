#!/usr/bin/env node
// The build-up states the opening chapter's MOTION takes film: the same song,
// with the layers that had not been added yet REMOVED, so the picture under
// "drums only" shows drums only. (features/record-all.sh: "THE PROJECT COLUMN
// MUST MATCH THE AUDIO" — a lane on screen that the viewer cannot hear is the
// defect class an observer keeps finding.)
//
//   node derive-states.mjs   -> work/states/{s-drums,s-band,s-lead}/
//
// Derived from states/sung by track.remove only: every remaining clip is the
// same clip, byte for byte, as in the stills built on camera by build-song.mjs.
import { open, close, cmd } from "./wire.mjs";
import { openState, saveState } from "./states.mjs";

const PLAN = { "s-drums": ["drums"], "s-band": ["drums", "bass", "pad"], "s-lead": ["drums", "bass", "pad", "lead"] };
await open();
try {
  for (const [state, keep] of Object.entries(PLAN)) {
    await openState("sung");
    const ov = await cmd("project.overview", {});
    for (const t of ov.tracks)
      if (!keep.some((k) => t.name.toLowerCase().startsWith(k))) await cmd("track.remove", { trackId: t.id });
    // Every kept track SOUNDS in these stages: unmute explicitly, because
    // mute-lead.mjs mutes Lead in states/sung after the fact, and a re-run of
    // this script would otherwise inherit that mute into s-lead.
    for (const t of (await cmd("project.overview", {})).tracks)
      await cmd("track.setMute", { trackId: t.id, muted: false });
    const after = (await cmd("project.overview", {})).tracks.map((t) => t.name);
    if (after.length !== keep.length) throw new Error(`${state}: left ${after}`);
    await saveState(state);
    console.log(`${state}: ${after.join(", ")}`);
  }
} catch (err) {
  console.error("⛔", err?.stack || err);
  process.exitCode = 1;
} finally {
  close();
  process.exit(process.exitCode ?? 0);
}
