#!/usr/bin/env node
// Every render the film plays or measures, from the SAVED STATES only
// (work/states/<state>/), through render.mixdown with excludeTrackIds — the
// project's own mutes, dirty flag and undo stack are untouched.
//
//   node render-all.mjs            -> out/renders/<state>-<mix>.wav (+ renders.json)
//
// Mixes are named by the tracks they KEEP (a track is matched by the start of
// its name). `vocal` is the lead vocal ALONE, from the clip's first beat (8.1),
// so its seconds equal the editor's note seconds — that is what tools/pitch.py
// and tools/voicesize.py read.
import { mkdirSync, writeFileSync } from "node:fs";
import { open, close, cmd, VOICE_HOME } from "./wire.mjs";
import { openState } from "./states.mjs";

const OUT = `${VOICE_HOME}/out/renders`;
mkdirSync(OUT, { recursive: true });
const SONG = ["drums", "bass", "pad", "vocals", "harmony"];
const PLAN = {
  sung:          { drums: ["drums"], band: ["drums", "bass", "pad"], bandlead: ["drums", "bass", "pad", "lead"],
                   song: SONG, vocal: "VOCAL" },
  sour:          { song: SONG, vocal: "VOCAL" },
  tuned:         { song: SONG, mix: ["drums", "bass", "pad", "vocals"], vocal: "VOCAL" },
  hard:          { song: SONG, vocal: "VOCAL" },
  "octave-keep": { mix: ["drums", "bass", "pad", "vocals"], vocal: "VOCAL" },
  "octave-off":  { mix: ["drums", "bass", "pad", "vocals"], vocal: "VOCAL" },
  deeper:        { song: SONG, vocal: "VOCAL" },
};

const only = process.argv.slice(2);
const index = {};
await open();
try {
  for (const [state, mixes] of Object.entries(PLAN)) {
    if (only.length && !only.includes(state)) continue;
    await openState(state);
    const ov = await cmd("project.overview", {});
    for (const [mix, keep] of Object.entries(mixes)) {
      const isVocal = keep === "VOCAL";
      const names = isVocal ? ["vocals"] : keep;
      for (const k of names) {
        if (!ov.tracks.some((t) => t.name.toLowerCase().startsWith(k)))
          throw new Error(`${state}: no track named like "${k}"`);
      }
      const exclude = ov.tracks.filter((t) => !names.some((k) => t.name.toLowerCase().startsWith(k))).map((t) => t.id);
      const path = `${OUT}/${state}-${mix}.wav`;
      const params = { path, ...(exclude.length ? { excludeTrackIds: exclude } : {}),
                       ...(isVocal ? { fromBeat: 8.1, durationSeconds: 20 } : {}) };
      const r = await cmd("render.mixdown", params, 600000);
      index[`${state}-${mix}`] = { path, state, keep: names, seconds: r.durationSeconds,
                                   fromBeat: params.fromBeat ?? 0 };
      console.log(`${state}-${mix}: ${Number(r.durationSeconds).toFixed(2)} s  kept=[${names}]`);
    }
  }
  writeFileSync(`${OUT}/renders.json`, JSON.stringify(index, null, 2));
} catch (err) {
  console.error("⛔", err?.stack || err);
  process.exitCode = 1;
} finally {
  close();
  process.exit(process.exitCode ?? 0);
}
