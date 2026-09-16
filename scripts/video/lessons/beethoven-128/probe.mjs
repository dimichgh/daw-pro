// Throwaway probe, KEPT because the choices it made are otherwise
// unexplainable. Builds the project on STAGING, renders the two versions at the
// current volumes, and prints their loudness so the volumes can be trimmed
// until the two sit within ~1.5 LU of each other.
//
// The band numbers are measured by probe.py, off these same wavs.
import { open, cmd, addTrack, addClip, close } from "../../session/build.mjs";
import { PARTS, BPM, LEN_BEATS, SECS, NOTE_COUNT } from "./material.mjs";

const AUD = process.env.B128_AUDIO || "./audio";
const REN = SECS + 1.5;

await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: BPM });

const ids = {};
for (const p of PARTS) {
  const t = await addTrack(p.name, { instrument: p.instrument,
                                     volume: p.volume, pan: p.pan });
  await addClip(t, 0, LEN_BEATS, p.notes, p.name);
  ids[p.name] = t;
}
console.log(`  ${NOTE_COUNT} notes across ${PARTS.length} tracks, ${SECS}s`);

const orch = PARTS.filter(p => p.group === "orch").map(p => ids[p.name]);
const tech = PARTS.filter(p => p.group === "tech").map(p => ids[p.name]);

// ⚠ `render.measureLoudness` HAS NO excludeTrackIds and `track.setMuted` IS
// NOT A COMMAND (it is `track.setMute`). `render.bounce` does both jobs in one
// call: it writes the file AND returns a measured loudness report for exactly
// the render it wrote, with the excluded tracks silenced. Omitting `lufsTarget`
// keeps it un-normalised, so the number describes the material.
async function bounce(name, exclude) {
  const r = await cmd("render.bounce",
    { path: `${AUD}/${name}.wav`, durationSeconds: REN, excludeTrackIds: exclude });
  return r;
}

for (const [name, excl] of [["orch", tech], ["techno", orch]]) {
  const r = await bounce(name, excl);
  const o = r.report.output;
  console.log(`  ${name.padEnd(7)} ${o.integratedLufs.toFixed(2)} LUFS  ` +
              `${o.truePeakDbtp.toFixed(2)} dBTP  LRA ${(o.loudnessRangeLu ?? NaN).toFixed(2)}`);
}

for (const p of PARTS) {
  await bounce(`stem-${p.name.toLowerCase()}`,
               PARTS.filter(q => q.name !== p.name).map(q => ids[q.name]));
}
console.log("  stems rendered");
await close();
