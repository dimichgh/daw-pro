// Throwaway probe: does this material HAVE the film's subject?
// The premise is "the gain that reaches −14 LUFS pushes the peak past 0 dBFS",
// which is a property of the MIX's crest factor, not of −14. Build it, render
// it dry, and check (−14 − LUFS) + peakDbfs > 0 before writing anything else.
import { open, cmd, addTrack, addClip, close } from "../../session/build.mjs";
import { PARTS, BPM, LEN_BEATS, SECS, NOTE_COUNT } from "./material.mjs";

const AUD = process.env.C14_AUDIO || "./audio";

await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: BPM });
for (const p of PARTS) {
  const t = await addTrack(p.name, { instrument: p.instrument, volume: p.volume, pan: p.pan });
  await addClip(t, 0, LEN_BEATS, p.notes, p.name);
  console.log(`  ${p.name}: ${p.notes.length} notes`);
}
console.log(`  total ${NOTE_COUNT} notes, ${SECS}s`);
const r = await cmd("render.mixdown", { path: `${AUD}/probe-dry.wav`, durationSeconds: SECS + 1.5 });
console.log(`  probe-dry.wav ${r.durationSeconds?.toFixed?.(2)}s`);
const m = await cmd("render.measureLoudness", { durationSeconds: SECS + 1.5 });
console.log(JSON.stringify(m.measurement, null, 1));
close();
process.exit(0);
