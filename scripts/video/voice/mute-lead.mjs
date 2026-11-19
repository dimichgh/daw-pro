#!/usr/bin/env node
// From the sung vocal on, the film never plays the piano Lead (every song
// render EXCLUDES it: render-all.mjs). An arrange take that shows the Lead
// lane UNMUTED would show a track the viewer cannot hear — so in every state
// after "sung" the Lead track is MUTED, and its M lights on screen.
//
//   node mute-lead.mjs    (idempotent)
//
// ⚠ This changes no audio the film plays: the renders already left the Lead out
// (verified after running this by re-rendering tuned-song and comparing).
import { open, close, cmd } from "./wire.mjs";
import { openState, saveState } from "./states.mjs";

await open();
try {
  for (const s of ["sung", "sour", "tuned", "hard", "octave-keep", "octave-off", "deeper"]) {
    await openState(s);
    const lead = (await cmd("project.overview", {})).tracks.find((t) => t.name === "Lead");
    if (!lead) throw new Error(`${s}: no Lead track`);
    await cmd("track.setMute", { trackId: lead.id, muted: true });
    const after = (await cmd("project.overview", {})).tracks.find((t) => t.name === "Lead");
    console.log(s, JSON.stringify(Object.fromEntries(Object.entries(after).filter(([k]) => /mute/i.test(k)))));
    await saveState(s);
  }
} catch (err) {
  console.error("⛔", err?.stack || err);
  process.exitCode = 1;
} finally {
  close();
  process.exit(process.exitCode ?? 0);
}
