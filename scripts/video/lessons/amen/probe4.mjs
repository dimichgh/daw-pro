// Does a second note on the SAME drum key cut the first one's ring?
// Hypothesis raised by a contradiction: adding 10 quiet ghost notes made the
// render 0.70 LUFS QUIETER while its broadband RMS went UP 0.11 dB.
// A: one accent alone.  B: the same accent + a quiet hit 331 ms later.
// C (control): the same accent + a quiet hit on a DIFFERENT key (40, electric
//    snare) 331 ms later -- if B truncates and C does not, it is key-stealing.
import { open, cmd, addTrack, addClip, n, close } from "../../session/build.mjs";
import * as M from "./material.mjs";
const AUD = new URL("./audio/", import.meta.url).pathname;
await open();
for (const [tag, notes] of [
  ["A", [n(0, 38, 0.24, 110)]],
  ["B", [n(0, 38, 0.24, 110), n(0.75, 38, 0.18, 50)]],
  ["C", [n(0, 38, 0.24, 110), n(0.75, 40, 0.18, 50)]],
]) {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: M.BPM });
  const t = await addTrack("Kit", { instrument: M.KIT });
  await addClip(t, 0, 8, notes, tag);
  await cmd("render.mixdown", { path: `${AUD}choke-${tag}.wav`, durationSeconds: 3.0 });
}
console.log("choke-A/B/C written");
close(); process.exit(0);
