// ⭐ DID EVERY PROGRAM ACTUALLY MAKE A SOUND? A sound-bank program that fails to
// load plays SILENCE and nothing upstream says so: the render succeeds, the
// loudness is plausible because twenty-five other tracks are playing, and the
// only symptom is an instrument you cannot hear. Nobody in this pipeline has
// ears, so this is the check that stands in for listening.
//
// Rebuilds DIR's project on staging and renders per-track stems; measure.py
// then reads each stem's RMS. A track with notes and a silent stem is the
// defect this exists to find.
import { open, cmd, close } from "/Users/dsemenov/Views/daw-pro/scripts/video/session/build.mjs";
import fs from "node:fs";
import path from "node:path";
const outDir = path.resolve(process.argv[3]);
const dir = path.join(outDir, "stems");
fs.mkdirSync(dir, { recursive: true });
const song = JSON.parse(fs.readFileSync(path.resolve(process.argv[2]), "utf8"));
await open();
const r = await cmd("render.stems", { directory: dir, fromBeat: 0,
                                      durationSeconds: song.renderSeconds,
                                      includeMixdown: false });
fs.writeFileSync(path.join(outDir, "stems.json"), JSON.stringify(r, null, 1));
console.log(`stems -> ${dir}  (${(r.files || r.stems || []).length} files)`);
close(); process.exit(0);
