// Solo-render each part at a KNOWN volume so the mix can be balanced by
// arithmetic instead of by ear (nobody here has ears).
// ⚠ It re-sets every instrument first: MEASURED, a soundBank instrument
// renders SILENT after the transport has been run for a burst, and a silent
// render reports ok.
import fs from "node:fs";
import { open, cmd, close } from "../../session/build.mjs";
import * as M from "./material.mjs";
const A = "/Users/dsemenov/Views/daw-pro/scripts/video/lessons/bach-house/audio";
const LOG = [];
await open();
const ov = await cmd("project.overview", {});
const ids = Object.fromEntries(ov.tracks.map((t) => [t.name, t.id]));
for (const p of M.PARTS)
  await cmd("track.setInstrument", { trackId: ids[p.name], ...p.instrument });
for (const p of M.PARTS) {
  const ex = Object.values(ids).filter((x) => x !== ids[p.name]);
  const r = await cmd("render.bounce", { path: `${A}/probe-${p.name}.wav`, fromBeat: 32,
                                         durationSeconds: 8, excludeTrackIds: ex });
  const line = `${p.name.padEnd(8)} vol ${p.volume}  ${r.report?.output?.integratedLufs?.toFixed(2)} LUFS  tp ${r.report?.output?.truePeakDbtp?.toFixed(2)}`;
  console.log("  " + line); LOG.push(line);
}
fs.writeFileSync("/Users/dsemenov/Views/daw-pro/scripts/video/lessons/bach-house/probe.txt", LOG.join("\n") + "\n");
await close();
