// The velocity -> level law, MEASURED OFF A RENDER, because
// instrument.probeLiveness disagreed with a render on two of four drums
// (probe2.mjs). One hit per beat, ascending velocity, one file per drum.
import { open, cmd, addTrack, addClip, n, close } from "../../session/build.mjs";
import fs from "node:fs";

const GUGS = "/Users/dsemenov/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2";
const KIT = { kind: "soundBank", soundBank: { source: GUGS, program: 0, bankMSB: 120 } };
const AUD = new URL("./audio/", import.meta.url).pathname;
export const VELS = [10, 20, 30, 40, 50, 52, 55, 60, 70, 74, 80, 90, 100, 110, 118, 120, 127];

await open();
for (const [name, pitch] of [["snare", 38], ["kick", 36], ["ride", 51], ["hat", 42]]) {
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: 120 });          // 1 beat = 0.5 s
  const t = await addTrack("Kit", { instrument: KIT });
  await addClip(t, 0, VELS.length + 2, VELS.map((v, i) => n(i, pitch, 0.4, v)), "vel");
  await cmd("render.mixdown", { path: `${AUD}vel-${name}.wav`,
                                durationSeconds: (VELS.length + 1) * 0.5 });
  console.log(`vel-${name}.wav  pitch ${pitch}  ${VELS.length} hits`);
}
fs.writeFileSync(new URL("./media/_vels.json", import.meta.url).pathname,
                 JSON.stringify({ velocities: VELS, bpm: 120, hitSeconds: 0.5 }, null, 1));
close(); process.exit(0);
