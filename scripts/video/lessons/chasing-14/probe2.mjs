// Balance probe: render each part alone (render.mixdown excludeTrackIds) and
// report its integrated LUFS against the full mix, so "is this still a mix or
// is it a drum loop with decoration" is a measurement rather than a guess.
import { open, cmd, addTrack, addClip, close } from "../../session/build.mjs";
import { PARTS, BPM, LEN_BEATS, SECS } from "./material.mjs";

const AUD = process.env.C14_AUDIO || "./audio";
await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: BPM });
const ids = [];
for (const p of PARTS) {
  const t = await addTrack(p.name, { instrument: p.instrument, volume: p.volume, pan: p.pan });
  await addClip(t, 0, LEN_BEATS, p.notes, p.name);
  ids.push(t);
}
const full = await cmd("render.measureLoudness", { durationSeconds: SECS + 1.5 });
console.log(`FULL  ${full.measurement.integratedLufs.toFixed(2)} LUFS  peak ${full.measurement.truePeakDbtp.toFixed(2)} dBTP  LRA ${full.measurement.loudnessRangeLu.toFixed(2)}`);
for (let i = 0; i < PARTS.length; i++) {
  const others = ids.filter((_, j) => j !== i);
  const r = await cmd("render.bounce", {
    path: `${AUD}/_stem-${PARTS[i].name}.wav`, durationSeconds: SECS + 1.5,
    excludeTrackIds: others,
  });
  const m = r.report.input;
  console.log(`  ${PARTS[i].name.padEnd(6)} ${m.integratedLufs.toFixed(2)} LUFS  peak ${m.truePeakDbtp.toFixed(2)} dBTP`);
}
close();
process.exit(0);
